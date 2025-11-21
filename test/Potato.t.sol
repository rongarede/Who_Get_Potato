// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../src/Potato.sol";
import "forge-std/console.sol"; // For debugging

contract PotatoTest is Test {
    // Manually declare the error to make it visible to the test contract compiler.
    // This error is defined in OpenZeppelin's ERC721.sol, but needs to be visible here for vm.expectRevert or try/catch.
    error ERC721NonexistentToken(uint256 tokenId);

    Potato public potato;
    address public userA = address(0xA);
    address public userB = address(0xB);
    address public userC = address(0xC);

    function setUp() public {
        vm.prank(userA);
        potato = new Potato();
    }

    /**
     * Test Case 1: A successful toss and safe landing.
     */
    function test_toss_and_safe_land() public {
        // 1. Check initial state
        assertEq(potato.ownerOf(potato.POTATO_ID()), userA);
        assertEq(uint(potato.currentState()), uint(Potato.GameState.Idle));

        // 2. UserA tosses to userB
        vm.prank(userA);
        potato.tossPotato(userB);

        // 3. Verify in-flight state by destructuring the returned tuple
        assertEq(uint(potato.currentState()), uint(Potato.GameState.InFlight));
        (address holder, , uint256 tossBlockNumber, address pendingReceiver) = potato.gameInfo();
        assertEq(holder, userA);
        assertEq(pendingReceiver, userB);
        assertTrue(tossBlockNumber > 0);

        // 4. Advance 2 blocks and resolve the toss
        vm.roll(block.number + 2);

        // We need to get the lastTransferTime *before* resolving
        (, uint256 lastTransferTimeBeforeResolve, ,) = potato.gameInfo();

        vm.expectEmit(true, true, true, true);
        emit Potato.PotatoLanded(userA, userB, block.timestamp - lastTransferTimeBeforeResolve);

        vm.prank(userC); // Anyone can resolve
        potato.resolveToss();

        // 5. Verify final state
        assertEq(potato.ownerOf(potato.POTATO_ID()), userB);
        assertEq(uint(potato.currentState()), uint(Potato.GameState.Idle));
        
        (address newHolder, , , address newPendingReceiver) = potato.gameInfo();
        assertEq(newHolder, userB);
        assertEq(newPendingReceiver, address(0));
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

    /**
     * Test Case 2: A toss that results in an explosion due to timeout.
     */
    function test_toss_and_explode_by_timeout() public {
        // 1. UserA tosses to userB
        vm.prank(userA);
        potato.tossPotato(userB);

        // 2. Get state before advancing blocks
        (address holderBefore, uint256 lastTransferTimeBefore, ,) = potato.gameInfo();

        // 3. Advance 257 blocks to trigger the timeout condition
        vm.roll(block.number + 257);

        // 4. Resolve the toss
        potato.resolveToss();

        // 5. Verify the potato is burned using our custom helper
        _assertOwnerOfReverts(potato.POTATO_ID());
    }
}
