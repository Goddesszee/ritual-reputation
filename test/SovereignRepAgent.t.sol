// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/SovereignRepAgent.sol";

contract SovereignRepAgentTest is Test {
    SovereignRepAgent public agent;

    address public user      = address(0xBEEF);
    address public user2     = address(0xCAFE);
    address constant SCHEDULER     = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;
    address constant LLM            = 0x0000000000000000000000000000000000000802;

    function setUp() public {
        agent = new SovereignRepAgent();
        vm.deal(user,  1 ether);
        vm.deal(user2, 1 ether);
        vm.deal(address(agent), 0.1 ether);
    }

    // ── Lifecycle ──────────────────────────────────────────────

    function test_OnlyOwnerCanStart() public {
        vm.prank(user);
        vm.expectRevert(SovereignRepAgent.NotOwner.selector);
        agent.startAgent();
    }

    function test_StartAgentSetsRunning() public {
        // Mock the Scheduler so startAgent doesn't revert on precompile
        vm.mockCall(SCHEDULER, abi.encodeWithSelector(IScheduler.schedule.selector), abi.encode(uint256(1)));
        agent.startAgent();
        (bool running,,,,,,) = agent.getAgentStatus();
        assertTrue(running);
    }

    function test_CannotStartTwice() public {
        vm.mockCall(SCHEDULER, abi.encodeWithSelector(IScheduler.schedule.selector), abi.encode(uint256(1)));
        agent.startAgent();
        vm.expectRevert(SovereignRepAgent.AlreadyRunning.selector);
        agent.startAgent();
    }

    // ── WakeUp ────────────────────────────────────────────────

    function test_OnlySchedulerCanWake() public {
        vm.prank(user);
        vm.expectRevert(SovereignRepAgent.NotScheduler.selector);
        agent.wakeUp(1);
    }

    function test_WakeUpIncrementsCounter() public {
        vm.mockCall(SCHEDULER, abi.encodeWithSelector(IScheduler.schedule.selector), abi.encode(uint256(1)));
        agent.startAgent();

        vm.prank(SCHEDULER);
        agent.wakeUp(1);

        (,uint256 wakeups,,,,,) = agent.getAgentStatus();
        assertEq(wakeups, 1);
    }

    // ── Score Request ─────────────────────────────────────────

    function test_RequestFeeRequired() public {
        vm.prank(user);
        vm.expectRevert(SovereignRepAgent.InsufficientFee.selector);
        agent.requestScore{value: 0}();
    }

    function test_RequestRegistersWallet() public {
        bytes32 mockJobId = keccak256("job1");
        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(mockJobId));

        vm.prank(user);
        agent.requestScore{value: 0.001 ether}();

        address[] memory wallets = agent.getRegisteredWallets();
        assertEq(wallets.length, 1);
        assertEq(wallets[0], user);
        assertTrue(agent.isRegistered(user));
    }

    function test_FeesAccrueToAgent() public {
        bytes32 mockJobId = keccak256("job2");
        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(mockJobId));

        vm.prank(user);
        agent.requestScore{value: 0.001 ether}();

        (,,,uint256 earnings,,,) = agent.getAgentStatus();
        assertEq(earnings, 0.001 ether);
    }

    function test_NoDuplicatePendingJobs() public {
        bytes32 mockJobId = keccak256("job3");
        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(mockJobId));

        vm.prank(user);
        agent.requestScore{value: 0.001 ether}();

        vm.prank(user);
        vm.expectRevert(SovereignRepAgent.JobAlreadyPending.selector);
        agent.requestScore{value: 0.001 ether}();
    }

    // ── Score Delivery ────────────────────────────────────────

    function test_OnlyAsyncDeliveryCanDeliver() public {
        vm.prank(user);
        vm.expectRevert(SovereignRepAgent.NotAsyncDelivery.selector);
        agent.receiveScore(bytes32(0), bytes('{"score":500,"tier":3,"reasoning":"test"}'));
    }

    function test_FullScoreFlow() public {
        bytes32 mockJobId = keccak256("score-flow");
        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(mockJobId));

        vm.prank(user);
        agent.requestScore{value: 0.001 ether}();

        // TEE delivers result via AsyncDelivery
        vm.prank(ASYNC_DELIVERY);
        agent.receiveScore(mockJobId, bytes('{"score":820,"tier":4,"reasoning":"Highly active DeFi participant"}'));

        (uint16 score, uint8 tier, string memory tierName,, bool isValid,) = agent.getScore(user);
        assertEq(score, 820);
        assertEq(tier, 4);
        assertEq(tierName, "Platinum");
        assertTrue(isValid);
    }

    function test_IsEligibleWorks() public {
        bytes32 mockJobId = keccak256("eligible-test");
        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(mockJobId));

        vm.prank(user);
        agent.requestScore{value: 0.001 ether}();

        vm.prank(ASYNC_DELIVERY);
        agent.receiveScore(mockJobId, bytes('{"score":600,"tier":3,"reasoning":"Good standing"}'));

        assertTrue(agent.isEligible(user, 500));
        assertFalse(agent.isEligible(user, 750));
        assertFalse(agent.isEligible(user2, 100)); // user2 never scored
    }

    function test_TotalScoredIncrements() public {
        bytes32 jobId1 = keccak256("total1");
        bytes32 jobId2 = keccak256("total2");
        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(jobId1));

        vm.prank(user);
        agent.requestScore{value: 0.001 ether}();

        vm.mockCall(LLM, abi.encodeWithSelector(bytes4(keccak256("requestInference((string,string,string,uint256))"))), abi.encode(jobId2));

        vm.prank(user2);
        agent.requestScore{value: 0.001 ether}();

        vm.prank(ASYNC_DELIVERY);
        agent.receiveScore(jobId1, bytes('{"score":300,"tier":2,"reasoning":"Silver"}'));
        vm.prank(ASYNC_DELIVERY);
        agent.receiveScore(jobId2, bytes('{"score":700,"tier":3,"reasoning":"Gold"}'));

        (,,uint256 total,,,,) = agent.getAgentStatus();
        assertEq(total, 2);
    }

    // ── Admin ────────────────────────────────────────────────

    function test_OwnerCanWithdraw() public {
        uint256 before = address(this).balance;
        agent.withdraw();
        assertGt(address(this).balance, before);
    }

    function test_NonOwnerCannotWithdraw() public {
        vm.prank(user);
        vm.expectRevert(SovereignRepAgent.NotOwner.selector);
        agent.withdraw();
    }
}

interface IScheduler {
    function schedule(address, bytes calldata, uint32) external returns (uint256);
    function cancel(uint256) external;
}
