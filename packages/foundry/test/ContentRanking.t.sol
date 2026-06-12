// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ContentRanking } from "../contracts/ContentRanking.sol";

contract ContentRankingTest is Test {
    ContentRanking internal ranking;
    address internal owner = address(0xABCD);

    function setUp() public {
        ranking = new ContentRanking(address(0), owner);
    }

    function testConstructorDefaults() public view {
        assertEq(ranking.owner(), owner);
        assertEq(ranking.burnPerVote(), 1e18);
        assertEq(ranking.votingDuration(), 7 days);
        assertEq(ranking.disputeDuration(), 24 hours);
        assertEq(ranking.disputeStakeRequired(), 0.001 ether);
        assertEq(address(ranking.clawdToken()), address(0));
    }

    function testSubmitContent() public {
        uint256 id = ranking.submitContent(
            "My Film", "A short film", ContentRanking.ContentType.Film, "QmCID"
        );
        assertEq(id, 0);
        assertEq(ranking.contentCount(), 1);

        ContentRanking.Content memory c = ranking.getContent(id);
        assertEq(c.creator, address(this));
        assertEq(c.title, "My Film");
        assertEq(uint256(c.status), uint256(ContentRanking.ContentStatus.Active));
        assertTrue(ranking.isVotingOpen(id));
    }

    function testVoteRevertsWhenClawdNotSet() public {
        uint256 id = ranking.submitContent("t", "d", ContentRanking.ContentType.Art, "QmCID");
        vm.expectRevert(ContentRanking.ClawdTokenNotSet.selector);
        ranking.vote(id, true, 1e18);
    }

    function testDisputeAndResolve() public {
        uint256 id = ranking.submitContent("t", "d", ContentRanking.ContentType.Music, "QmCID");

        address disputer = address(0xBEEF);
        vm.deal(disputer, 1 ether);
        vm.prank(disputer);
        ranking.dispute{ value: 0.001 ether }(id);

        ContentRanking.Content memory c = ranking.getContent(id);
        assertEq(uint256(c.status), uint256(ContentRanking.ContentStatus.Disputed));
        assertEq(c.disputer, disputer);

        // Upheld: content removed and stake refunded.
        vm.prank(owner);
        ranking.resolveDispute(id, true);

        c = ranking.getContent(id);
        assertEq(uint256(c.status), uint256(ContentRanking.ContentStatus.Removed));
        assertEq(disputer.balance, 1 ether);
    }

    function testOnlyOwnerResolveDispute() public {
        uint256 id = ranking.submitContent("t", "d", ContentRanking.ContentType.Writing, "QmCID");
        vm.deal(address(this), 1 ether);
        ranking.dispute{ value: 0.001 ether }(id);

        vm.expectRevert();
        ranking.resolveDispute(id, true);
    }

    function testWithdrawETHFromRetainedStake() public {
        uint256 id = ranking.submitContent("t", "d", ContentRanking.ContentType.Art, "QmCID");
        vm.deal(address(this), 1 ether);
        ranking.dispute{ value: 0.001 ether }(id);

        // Not upheld: stake retained as treasury.
        vm.prank(owner);
        ranking.resolveDispute(id, false);
        assertEq(address(ranking).balance, 0.001 ether);

        vm.prank(owner);
        ranking.withdrawETH(owner);
        assertEq(owner.balance, 0.001 ether);
    }

    receive() external payable { }
}
