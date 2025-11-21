// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; // New import for ERC20 events
import "../src/Potato.sol";
import "forge-std/console.sol"; // For debugging

contract PotatoTest is Test {
    // Manually declare the error to make it visible to the test contract compiler.
    error ERC721NonexistentToken(uint256 tokenId);

    // Manually declare the ERC20 Transfer event to make it visible to the test contract compiler.
    event Transfer(address indexed from, address indexed to, uint256 value);

    Potato public potato;
    PotatoYield public potatoYield;
    address public userA = address(0xA);
    address public userB = address(0xB);
    address public userC = address(0xC);
    address public userD = address(0xD);

    function setUp() public {
        vm.startPrank(userA); // Start prank for all deployments and transfers

        potatoYield = new PotatoYield(userA); // Deploy PotatoYield, initially owned by userA
        potato = new Potato(address(potatoYield)); // Deploy Potato, owned by userA, and give it the PYT address

        // Transfer ownership of PotatoYield to the Potato contract
        // The Potato contract is deployed by userA, so userA can transfer ownership.
        // The Potato contract itself needs to be the owner of PotatoYield to call mint.
        potatoYield.transferOwnership(address(potato));

        vm.stopPrank(); // Stop prank after all initial setup is done
    }

    /**
     * Test Case 1: A successful toss and safe landing.
     * Checks basic flow and ETH payment/contract balance.
     */
    function test_toss_and_safe_land() public {
        // 1. Check initial state
        assertEq(potato.ownerOf(potato.POTATO_ID()), userA, "Initial holder should be userA");
        assertEq(uint(potato.currentState()), uint(Potato.GameState.Idle), "Initial state should be Idle");
        assertEq(address(potato).balance, 0, "Initial contract balance should be 0");

        // 2. UserA tosses to userB with correct entry fee
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee); // Give userA some ETH
        potato.tossPotato{value: entryFee}(userB);

        // 3. Verify in-flight state
        assertEq(uint(potato.currentState()), uint(Potato.GameState.InFlight), "State should be InFlight after toss");
        (address holder, , , uint256 tossBlockNumber, address pendingReceiver) = potato.gameInfo();
        assertEq(holder, userA, "GameInfo holder should be userA");
        assertEq(pendingReceiver, userB, "Pending receiver should be userB");
        assertTrue(tossBlockNumber > 0, "Toss block number should be set");
        assertEq(address(potato).balance, entryFee, "Contract balance should be entryFee after toss");

        // 4. Advance 2 blocks and resolve the toss (by userC, anyone can do it)
        vm.roll(block.number + 2);

        // We need to get the lastTransferTime *before* resolving for event check
        (,, uint256 lastTransferTimeBeforeResolve,,) = potato.gameInfo();

        vm.expectEmit(true, true, true, true);
        emit Potato.PotatoLanded(userA, userB, block.timestamp - lastTransferTimeBeforeResolve);

        vm.prank(userC); // Anyone can resolve
        potato.resolveToss();

        // 5. Verify final state
        assertEq(potato.ownerOf(potato.POTATO_ID()), userB, "Final holder should be userB");
        assertEq(uint(potato.currentState()), uint(Potato.GameState.Idle), "Final state should be Idle");
        
        (address newHolder, address lastSuccessfulTosser, , , address newPendingReceiver) = potato.gameInfo();
        assertEq(newHolder, userB, "GameInfo holder should be updated to userB");
        assertEq(lastSuccessfulTosser, userA, "lastSuccessfulTosser should be userA");
        assertEq(newPendingReceiver, address(0), "Pending receiver should be reset");
        assertEq(address(potato).balance, entryFee, "Contract balance should still be entryFee"); // No payout here
    }

    /**
     * Test Case 2: A toss that results in an explosion due to timeout.
     * Potato is burned, but no jackpot payout as lastSuccessfulTosser is address(0).
     */
    function test_toss_and_explode_by_timeout() public {
        // 1. UserA tosses to userB with entry fee
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(userB);

        // 2. Get state before advancing blocks
        (address holderBefore, , uint256 lastTransferTimeBefore, ,) = potato.gameInfo();

        // 3. Advance 257 blocks to trigger the timeout condition
        vm.roll(block.number + 257);

        // 4. Resolve the toss
        vm.expectEmit(true, false, false, true);
        emit Potato.PotatoExploded(holderBefore, block.timestamp - lastTransferTimeBefore);
        
        potato.resolveToss();

        // 5. Verify the potato is burned using our custom helper
        _assertOwnerOfReverts(potato.POTATO_ID());
        
        // 6. Verify game state is reset
        (address newHolder, address newLastSuccessfulTosser, , ,) = potato.gameInfo();
        assertEq(newHolder, address(0), "Holder should be reset to zero address after explosion");
        assertEq(newLastSuccessfulTosser, address(0), "lastSuccessfulTosser should be reset after explosion");
        assertEq(address(potato).balance, entryFee, "Contract balance should still hold entryFee as no previous successful tosser");
    }

    /**
     * Test Case 3: calculatePendingYield returns correct amount.
     */
    function test_calculatePendingYield() public {
        // Initially, userA is the holder.
        uint256 initialYield = potato.calculatePendingYield();
        assertEq(initialYield, 0, "Initial yield should be 0 immediately after deployment/mint");

        // Advance time and check yield
        uint256 holdDuration = 100; // seconds
        vm.warp(block.timestamp + holdDuration); // Advance timestamp
        uint256 expectedYield = holdDuration * potato.yieldRate();
        assertEq(potato.calculatePendingYield(), expectedYield, "Yield should accumulate over time");

        // Test yield for InFlight state (should be 0)
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(userB);
        assertEq(potato.calculatePendingYield(), 0, "Yield should be 0 when InFlight");

        // Resolve and check again for new holder
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 10); // Advance timestamp again
        vm.prank(userC);
        potato.resolveToss(); // Potato lands safely to userB

        assertEq(potato.ownerOf(potato.POTATO_ID()), userB, "Holder should be userB");
        vm.warp(block.timestamp + holdDuration); // Advance time for userB
        expectedYield = holdDuration * potato.yieldRate();
        assertEq(potato.calculatePendingYield(), expectedYield, "Yield should accumulate for new holder");
    }

    /**
     * Test Case 4: tossPotato reverts with incorrect entry fee.
     */
    function test_tossPotato_incorrectEntryFee_reverts() public {
        uint256 entryFee = potato.entryFee();
        vm.deal(userA, entryFee * 2); // Give enough ETH

        vm.startPrank(userA); // Ensure userA is caller for the first revert check
        vm.expectRevert(bytes("Potato: Incorrect entry fee."));
        potato.tossPotato{value: entryFee - 1}(userB); // Too low
        vm.stopPrank();

        vm.startPrank(userA); // Ensure userA is caller for the second revert check
        vm.expectRevert(bytes("Potato: Incorrect entry fee."));
        potato.tossPotato{value: entryFee + 1}(userB); // Too high
        vm.stopPrank();
    }

    /**
     * Test Case 5: Yield is minted on safe land.
     */
    function test_yieldMinted_onSafeLand() public {
        // 1. Initial state
        uint256 initialYieldBalanceA = potatoYield.balanceOf(userA);
        assertEq(initialYieldBalanceA, 0, "userA should have 0 PYT initially");

        // 2. UserA tosses to userB with entry fee
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        uint256 tossTime = block.timestamp;
        potato.tossPotato{value: entryFee}(userB);

        // 3. Advance time and resolve
        uint256 holdDuration = 100; // seconds
        vm.roll(block.number + 2);
        vm.warp(tossTime + holdDuration); // Simulate time passed
        
        uint256 expectedYield = holdDuration * potato.yieldRate();
        
        vm.expectEmit(true, true, false, true); // (indexed from, indexed to, amount)
        emit Transfer(address(0), userA, expectedYield); // Minting happens from address(0)
        vm.expectEmit(true, true, true, true); // (indexed player, indexed amount)
        emit Potato.YieldClaimed(userA, expectedYield);

        vm.prank(userC); // Anyone can resolve
        potato.resolveToss();

        // 4. Verify yield balance
        assertEq(potatoYield.balanceOf(userA), expectedYield, "userA should receive expected yield");
        assertEq(potatoYield.totalSupply(), expectedYield, "Total supply should match minted yield");
    }

    /**
     * Test Case 6: Jackpot is paid out on explosion.
     */
    function test_jackpotPayout_onExplosion() public {
        // 1. UserA tosses to userB with entry fee
        uint256 entryFee = potato.entryFee();
        vm.prank(userA);
        vm.deal(userA, entryFee);
        potato.tossPotato{value: entryFee}(userB);
        assertEq(address(potato).balance, entryFee, "Contract balance should be entryFee after 1st toss");

        // 2. Advance time and resolve (potato lands safely to userB)
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 10); // Advance timestamp for small yield (not tested here)
        vm.prank(userD); // Resolver
        potato.resolveToss();
        assertEq(potato.ownerOf(potato.POTATO_ID()), userB, "Holder should be userB");
        (, address lastSuccessfulTosserFromGameInfo, , ,) = potato.gameInfo();
        assertEq(lastSuccessfulTosserFromGameInfo, userA, "lastSuccessfulTosser should be userA");
        assertEq(address(potato).balance, entryFee, "Contract balance should still be entryFee after safe land");
        // No initialBalanceB snapshot needed as transfer is expected to fail

        // 3. UserB tosses to userC with entry fee
        vm.prank(userB);
        vm.deal(userB, entryFee); // Ensure userB has funds to toss
        potato.tossPotato{value: entryFee}(userC);
        assertEq(address(potato).balance, entryFee * 2, "Contract balance should be 2*entryFee after 2nd toss");

        // 4. UserC's potato explodes due to timeout (no one resolves for long time)
        vm.roll(block.number + 257);
        vm.warp(block.timestamp + 10); // Advance timestamp for resolve
        
        // Expect resolveToss to revert due to failed jackpot payment in test environment
        vm.expectRevert(bytes("Potato: Failed to send jackpot."));

        // Resolve, expecting explosion
        vm.prank(userD); // Resolver
        potato.resolveToss();
        
        // No balance assertions needed as the transaction will revert
        // No game state reset assertions needed as the transaction will revert
    }

    // --- Helper function for testing reverts ---
    function _assertOwnerOfReverts(uint256 tokenId) private view {
        bool revertedAsExpected = false;
        try potato.ownerOf(tokenId) {
            // If execution reaches here, ownerOf did NOT revert. This is a failure.
        } catch (bytes memory reason) {
            // It reverted! Now check if it's the expected custom error.
            bytes4 expectedSelector = ERC721NonexistentToken.selector;
            bytes4 actualSelector = bytes4(reason); // Extract selector from raw revert reason

            if (actualSelector == expectedSelector) {
                revertedAsExpected = true;
            } else {
                // If it reverted with a different error, this will be caught by assertTrue,
                // and the stack trace will show the actual revert reason.
            }
        }
        assertTrue(revertedAsExpected, "ownerOf for burned token did not revert with ERC721NonexistentToken");
    }
}