/*

    Copyright 2019 The Hydro Protocol Foundation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./Pool.sol";
import "../lib/Store.sol";
import "../lib/SafeMath.sol";
import "../lib/Types.sol";
import "../lib/Events.sol";
import "../lib/Decimal.sol";
import "../lib/Transfer.sol";

library Auctions {
    using SafeMath for uint256;
    using Auction for Types.Auction;

    function fillAuctionWithAmount(
        Store.State storage state,
        uint16 id,
        uint256 repayAmount
    )
        internal
    {
        Types.Auction storage auction = state.auction.auctions[id];

        address borrower = auction.borrower;
        uint16 marketID = auction.marketID;
        address debtAsset = auction.debtAsset;
        address collateralAsset = auction.collateralAsset;

        uint256 leftDebtAmount = Pool._getPoolBorrowOf(state, debtAsset, borrower, marketID);
        uint256 leftCollateralAmount = state.accounts[borrower][marketID].wallet.balances[collateralAsset];

        // transfer valid repay amount from msg.sender to borrower
        uint256 validRepayAmount = repayAmount < leftDebtAmount ? repayAmount : leftDebtAmount;

        state.wallets[msg.sender].balances[debtAsset] = state.wallets[msg.sender].balances[debtAsset].sub(validRepayAmount);
        state.accounts[borrower][marketID].wallet.balances[debtAsset] = state.accounts[borrower][marketID].wallet.balances[debtAsset].add(validRepayAmount);

        Pool.repay(
            state,
            borrower,
            marketID,
            debtAsset,
            repayAmount
        );

        uint256 ratio = auction.ratio(state);
        uint256 amountToProcess = leftCollateralAmount.mul(validRepayAmount).div(leftDebtAmount);
        uint256 amountForBidder = Decimal.mul(amountToProcess, ratio);
        uint256 amountForInitiator = Decimal.mul(amountToProcess.sub(amountForBidder), state.auction.initiatorRewardRatio);
        uint256 amountForBorrower = amountToProcess.sub(amountForBidder).sub(amountForInitiator);

        // bidder receive collateral
        state.wallets[msg.sender].balances[collateralAsset] = state.wallets[msg.sender].balances[collateralAsset].add(amountForBidder);

        // initiator receive collateral
        state.wallets[auction.initiator].balances[collateralAsset] = state.wallets[auction.initiator].balances[collateralAsset].add(amountForInitiator);

        // borrower receive collateral
        state.wallets[borrower].balances[collateralAsset] = state.wallets[borrower].balances[collateralAsset].add(amountForBorrower);

        Events.logFillAuction(id, repayAmount);

        // reset account state if all debts are paid
        if (leftDebtAmount <= repayAmount) {
            Events.logAuctionFinished(id);
            Types.CollateralAccount storage account = state.accounts[borrower][marketID];
            account.status = Types.CollateralAccountStatus.Normal;
            for (uint i = 0; i<state.auction.currentAuctions.length; i++){
                if (state.auction.currentAuctions[i]==id){
                    state.auction.currentAuctions[i] = state.auction.currentAuctions[state.auction.currentAuctions.length-1];
                    state.auction.currentAuctions.length--;
                }
            }
        }
    }

    function badDebt(
        Store.State storage state,
        uint16 id
    ) 
        internal
    {
        Types.Auction storage auction = state.auction.auctions[id];
        uint256 ratio = auction.ratio(state);
        require(ratio == Decimal.one(), "AUCTION_NOT_END");

        address borrower = auction.borrower;
        uint16 marketID = auction.marketID;
        address debtAsset = auction.debtAsset;
        address collateralAsset = auction.collateralAsset;

        // transfer insurance balance to borrower
        uint256 insuranceBalance = state.insuranceWallet.balances[debtAsset];
        state.accounts[borrower][marketID].wallet.balances[debtAsset] = state.accounts[borrower][marketID].wallet.balances[debtAsset].add(insuranceBalance);
        state.insuranceWallet.balances[debtAsset] = 0;

        Pool.repay(
            state,
            borrower,
            marketID,
            debtAsset,
            insuranceBalance
        );

        // transfer borrower balance back to insurance
        state.insuranceWallet.balances[debtAsset] = state.insuranceWallet.balances[debtAsset].add(state.accounts[borrower][marketID].wallet.balances[debtAsset]);state.insuranceWallet.balances[collateralAsset] = state.insuranceWallet.balances[collateralAsset].add(state.accounts[borrower][marketID].wallet.balances[collateralAsset]);

        uint256 badDebtAmount = Pool._getPoolBorrowOf(state, debtAsset, borrower, marketID);

        if (badDebtAmount > 0){
            uint256 totalLogicSupply = Pool._getTotalLogicSupply(state, debtAsset);
            uint256 actualSupply = Pool._getPoolTotalSupply(state, debtAsset).sub(badDebtAmount);
            state.pool.supplyIndex[debtAsset] = Decimal.divFloor(actualSupply, totalLogicSupply);
            state.pool.logicBorrow[borrower][marketID].balances[debtAsset] = 0;
        }
    }

    /**
     * Create an auction for a loan and save it in global state
     *
     */
    function create(
        Store.State storage state,
        uint16 marketID,
        address borrower,
        address initiator,
        address debtAsset,
        address collateralAsset
    )
        internal
    {
        uint32 id = state.auction.auctionsCount++;

        Types.Auction memory auction = Types.Auction({
            id: id,
            startBlockNumber: uint32(block.number),
            marketID: marketID,
            borrower: borrower,
            initiator: initiator,
            debtAsset: debtAsset,
            collateralAsset: collateralAsset
        });

        state.auction.auctions[id] = auction;
        state.auction.currentAuctions.push(id);

        Events.logAuctionCreate(id);
    }
}