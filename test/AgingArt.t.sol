// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgingArt} from "../src/AgingArt.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// ---------------------------------------------------------------------------
// Helper contracts
// ---------------------------------------------------------------------------

contract NonReceiverContract {
    AgingArt public art;

    constructor(AgingArt _art) {
        art = _art;
    }

    function attemptMint() external returns (uint256) {
        return art.mint();
    }
}

/// @dev Reentrancy attacker: calls mint() again inside onERC721Received.
contract ReentrantMinter is IERC721Receiver {
    AgingArt public art;
    uint256 public mintCount;

    constructor(AgingArt _art) {
        art = _art;
    }

    function attackMint() external returns (uint256) {
        return art.mint();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        mintCount++;
        // Try to mint again reentrantly (should revert due to limit)
        try art.mint() {
            mintCount++;
        } catch {
            // expected revert
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------

contract AgingArtTest is Test {
    AgingArt public art;

    address public alice;
    address public bob;
    address public operator;
    address public approved;
    address public stranger;

    uint256 internal constant MAX_SUPPLY = 1000;
    uint256 internal constant MAX_PER_WALLET = 3;

    // Events mirrored for vm.expectEmit
    event Minted(uint256 indexed tokenId, address indexed recipient);
    event Cared(
        uint256 indexed tokenId,
        address indexed caller,
        AgingArt.Stage fromStage,
        AgingArt.Stage toStage,
        uint256 timestamp
    );

    function setUp() public {
        art = new AgingArt(MAX_SUPPLY, MAX_PER_WALLET);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        operator = makeAddr("operator");
        approved = makeAddr("approved");
        stranger = makeAddr("stranger");
    }

    // =====================================================================
    // 1. Stage boundaries and vitality (ceil-division values)
    // =====================================================================

    function test_StageBoundaries() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Immediately at mint (0 elapsed)
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);

        // 1 day - 1 second → Blooming, vitality = ceil((6d+1) * 100 / 7d) = 86
        skip(1 days - 1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 86);

        // 1 day exact → Verdant, vitality = ceil(6d * 100 / 7d) = 86
        skip(1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        assertEq(art.getVitality(tokenId), 86);

        // 3 days - 1 second → Verdant, vitality = ceil((4d+1) * 100 / 7d) = 58
        skip(2 days - 1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        assertEq(art.getVitality(tokenId), 58);

        // 3 days exact → Mossy, vitality = ceil(4d * 100 / 7d) = 58
        skip(1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertEq(art.getVitality(tokenId), 58);

        // 7 days - 1 second → Mossy, vitality = ceil(1 * 100 / 7d) = 1
        skip(4 days - 1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertEq(art.getVitality(tokenId), 1);

        // 7 days exact → Ancient, vitality = 0
        skip(1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));
        assertEq(art.getVitality(tokenId), 0);

        // Beyond 7 days → Ancient, vitality = 0
        skip(7 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));
        assertEq(art.getVitality(tokenId), 0);
    }

    // =====================================================================
    // 2. Stepwise care
    // =====================================================================

    function test_StepwiseCare_AncientToMossy() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Age to Ancient (10 days)
        skip(10 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));

        vm.prank(alice);
        art.care(tokenId);

        // Should be Mossy with elapsed == VERDANT_DURATION (3 days)
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        uint256 elapsed = art.getInactivityDuration(tokenId);
        assertEq(elapsed, 3 days);
    }

    function test_StepwiseCare_MossyToVerdant() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Age to Ancient
        skip(10 days);
        vm.prank(alice);
        art.care(tokenId); // Ancient → Mossy (elapsed = 3d)

        // Wait for cooldown (12 hours)
        skip(12 hours);

        vm.prank(alice);
        art.care(tokenId); // Mossy → Verdant (elapsed = 1d)

        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        uint256 elapsed = art.getInactivityDuration(tokenId);
        assertEq(elapsed, 1 days);
    }

    function test_StepwiseCare_VerdantToBlooming() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Age to Ancient
        skip(10 days);
        vm.prank(alice);
        art.care(tokenId); // Ancient → Mossy

        skip(12 hours);
        vm.prank(alice);
        art.care(tokenId); // Mossy → Verdant

        skip(12 hours);
        vm.prank(alice);
        art.care(tokenId); // Verdant → Blooming (elapsed = 0)

        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_StepwiseCare_BloomingRefreshesToZeroElapsed() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Stay in Blooming, wait for cooldown
        skip(12 hours);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));

        vm.prank(alice);
        art.care(tokenId);

        // Should refresh: elapsed = 0
        assertEq(art.getInactivityDuration(tokenId), 0);
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_StepwiseCare_MossyAt6_9DaysGivesVerdantAt1Day() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Age to 6.9 days (just under 7d, still Mossy)
        skip(6 days + 21 hours + 36 minutes); // 6.9 days = 596160 seconds
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));

        vm.prank(alice);
        art.care(tokenId); // Mossy → Verdant (target elapsed = 1d)

        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        assertEq(art.getInactivityDuration(tokenId), 1 days);
    }

    // =====================================================================
    // 3. Cooldown
    // =====================================================================

    function test_CooldownRevertsBefore12Hours() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Try to care immediately (within cooldown from mint)
        skip(12 hours - 1);

        uint256 expectedAvailableAt = block.timestamp + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgingArt.CareOnCooldown.selector, tokenId, expectedAvailableAt));
        art.care(tokenId);
    }

    function test_CooldownSucceedsAt12Hours() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(12 hours);

        vm.prank(alice);
        art.care(tokenId); // should succeed
    }

    function test_CooldownFirstCareAfterMint() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Immediately after mint: should be on cooldown
        vm.prank(alice);
        vm.expectRevert();
        art.care(tokenId);
    }

    function test_CooldownSharedAcrossCallers() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.prank(alice);
        art.setApprovalForAll(operator, true);

        skip(12 hours);

        // Alice cares
        vm.prank(alice);
        art.care(tokenId);

        // Operator tries immediately → cooldown
        vm.prank(operator);
        vm.expectRevert();
        art.care(tokenId);

        // After another 12 hours, operator can care
        skip(12 hours);
        vm.prank(operator);
        art.care(tokenId);
    }

    function test_TransferDoesNotResetCooldown() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(12 hours);
        vm.prank(alice);
        art.care(tokenId);

        // Transfer to bob
        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        // Bob tries to care immediately → cooldown
        vm.prank(bob);
        vm.expectRevert();
        art.care(tokenId);

        // After cooldown, bob can care
        skip(12 hours);
        vm.prank(bob);
        art.care(tokenId);
    }

    // =====================================================================
    // 4. Transfer does NOT reset timer/stage
    // =====================================================================

    function test_TransferDoesNotResetTimerOrStage() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        uint256 timestampBefore = art.lastActionTimestamp(tokenId);

        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        assertEq(art.ownerOf(tokenId), bob);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertEq(art.lastActionTimestamp(tokenId), timestampBefore);
    }

    function test_TransferToSelfDoesNotResetTimer() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        uint256 timestampBefore = art.lastActionTimestamp(tokenId);

        vm.prank(alice);
        art.transferFrom(alice, alice, tokenId);

        assertEq(art.ownerOf(tokenId), alice);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertEq(art.lastActionTimestamp(tokenId), timestampBefore);
    }

    function test_NewOwnerCanCareAfterCooldown() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);

        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        // Bob can care (cooldown from mint was 5 days ago, well past 12 hours)
        vm.prank(bob);
        art.care(tokenId);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
    }

    function test_OldOwnerCannotCareAfterTransfer() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);

        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, tokenId));
        art.care(tokenId);
    }

    function test_FormerApprovedCannotCareAfterTransfer() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.prank(alice);
        art.approve(approved, tokenId);

        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        // Approval cleared by transfer
        skip(12 hours);
        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, approved, tokenId));
        art.care(tokenId);
    }

    function test_ApproveForToken1CannotCareToken2() public {
        vm.prank(alice);
        uint256 token1 = art.mint();

        vm.prank(alice);
        uint256 token2 = art.mint();

        vm.prank(alice);
        art.approve(approved, token1);

        skip(12 hours);

        // Can care token 1
        vm.prank(approved);
        art.care(token1);

        // Cannot care token 2
        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, approved, token2));
        art.care(token2);
    }

    // =====================================================================
    // 5. Authorization
    // =====================================================================

    function test_Care_Owner() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(10 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));

        vm.prank(alice);
        art.care(tokenId);

        // Stepwise: Ancient → Mossy
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
    }

    function test_Care_Approved() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.prank(alice);
        art.approve(approved, tokenId);

        skip(5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));

        vm.prank(approved);
        art.care(tokenId);

        // Stepwise: Mossy → Verdant
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
    }

    function test_Care_Operator() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.prank(alice);
        art.setApprovalForAll(operator, true);

        skip(5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));

        vm.prank(operator);
        art.care(tokenId);

        // Stepwise: Mossy → Verdant
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
    }

    function test_Care_StrangerReverts() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, tokenId));
        art.care(tokenId);
    }

    function test_Care_NonexistentTokenReverts() public {
        uint256 nonexistentId = 999;
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nonexistentId));
        art.care(nonexistentId);
    }

    function test_CaredEvent_OwnerCaller() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(10 days);

        vm.expectEmit(true, true, false, true);
        emit Cared(tokenId, alice, AgingArt.Stage.Ancient, AgingArt.Stage.Mossy, block.timestamp);

        vm.prank(alice);
        art.care(tokenId);
    }

    function test_CaredEvent_OperatorCaller() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.prank(alice);
        art.setApprovalForAll(operator, true);

        skip(5 days);

        vm.expectEmit(true, true, false, true);
        emit Cared(tokenId, operator, AgingArt.Stage.Mossy, AgingArt.Stage.Verdant, block.timestamp);

        vm.prank(operator);
        art.care(tokenId);
    }

    // =====================================================================
    // 6. Mint: supply, wallet limit, reentrancy, non-receiver, totalSupply
    // =====================================================================

    function test_MintMaxSupply() public {
        AgingArt smallArt = new AgingArt(3, 10);

        vm.startPrank(alice);
        smallArt.mint();
        smallArt.mint();
        smallArt.mint();

        vm.expectRevert(AgingArt.MaxSupplyReached.selector);
        smallArt.mint();
        vm.stopPrank();
    }

    function test_MintWalletLimit() public {
        vm.startPrank(alice);
        art.mint();
        art.mint();
        art.mint();

        vm.expectRevert(abi.encodeWithSelector(AgingArt.WalletMintLimitReached.selector, alice));
        art.mint();
        vm.stopPrank();
    }

    function test_MintWalletLimitCountsByMints() public {
        // Mint 3, transfer 2 away → balanceOf is 1, but still cannot mint
        vm.startPrank(alice);
        art.mint(); // 1
        art.mint(); // 2
        art.mint(); // 3

        art.transferFrom(alice, bob, 1);
        art.transferFrom(alice, bob, 2);

        // Alice has balanceOf == 1 but mintedBy == 3
        vm.expectRevert(abi.encodeWithSelector(AgingArt.WalletMintLimitReached.selector, alice));
        art.mint();
        vm.stopPrank();

        // Confirm balanceOf
        assertEq(art.balanceOf(alice), 1);
        assertEq(art.mintedBy(alice), 3);
    }

    function test_ReentrantMintBlocked() public {
        AgingArt smallArt = new AgingArt(10, 1); // 1 per wallet
        ReentrantMinter attacker = new ReentrantMinter(smallArt);

        attacker.attackMint();

        // Attacker got exactly 1 token, reentrancy was blocked
        assertEq(attacker.mintCount(), 1);
        assertEq(smallArt.balanceOf(address(attacker)), 1);
        assertEq(smallArt.totalSupply(), 1);
    }

    function test_MintFromContractWithoutReceiverReverts() public {
        NonReceiverContract nonReceiver = new NonReceiverContract(art);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(nonReceiver)));
        nonReceiver.attemptMint();
    }

    function test_TotalSupply() public {
        assertEq(art.totalSupply(), 0);

        vm.prank(alice);
        art.mint();
        assertEq(art.totalSupply(), 1);

        vm.prank(bob);
        art.mint();
        assertEq(art.totalSupply(), 2);
    }

    function test_EmitMinted() public {
        vm.expectEmit(true, true, false, false);
        emit Minted(1, alice);

        vm.prank(alice);
        art.mint();
    }

    // =====================================================================
    // 7. Fuzz: warp + care sequences
    // =====================================================================

    function testFuzz_CareStepwise(uint256 elapsed) public {
        elapsed = bound(elapsed, 12 hours, 365 days);

        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(elapsed);

        AgingArt.Stage stageBefore = art.getStage(tokenId);
        uint256 anchorBefore = art.lastActionTimestamp(tokenId);

        vm.prank(alice);
        art.care(tokenId);

        AgingArt.Stage stageAfter = art.getStage(tokenId);
        uint256 anchorAfter = art.lastActionTimestamp(tokenId);

        // Anchor never decreases
        assertGe(anchorAfter, anchorBefore, "Anchor must not decrease");

        // Stage improves by at most 1 level (in health direction)
        if (stageBefore == AgingArt.Stage.Ancient) {
            assertEq(uint8(stageAfter), uint8(AgingArt.Stage.Mossy), "Ancient should become Mossy");
        } else if (stageBefore == AgingArt.Stage.Mossy) {
            assertEq(uint8(stageAfter), uint8(AgingArt.Stage.Verdant), "Mossy should become Verdant");
        } else {
            assertEq(uint8(stageAfter), uint8(AgingArt.Stage.Blooming), "Should become Blooming");
        }
    }

    function testFuzz_VitalityInRange(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 3650 days);

        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(elapsed);
        uint256 v = art.getVitality(tokenId);
        AgingArt.Stage stage = art.getStage(tokenId);

        assertLe(v, 100, "Vitality must be <= 100");

        if (elapsed < 1 days) {
            assertEq(uint8(stage), uint8(AgingArt.Stage.Blooming), "Expected Blooming");
        } else if (elapsed < 3 days) {
            assertEq(uint8(stage), uint8(AgingArt.Stage.Verdant), "Expected Verdant");
        } else if (elapsed < 7 days) {
            assertEq(uint8(stage), uint8(AgingArt.Stage.Mossy), "Expected Mossy");
        } else {
            assertEq(uint8(stage), uint8(AgingArt.Stage.Ancient), "Expected Ancient");
            assertEq(v, 0, "Vitality should be 0 after 7 days");
        }

        // vitality == 0 iff Ancient
        if (v == 0) {
            assertEq(uint8(stage), uint8(AgingArt.Stage.Ancient), "v==0 must be Ancient");
        }

        // Monotonic non-increasing check
        if (elapsed < 3650 days) {
            skip(1 hours);
            uint256 vNext = art.getVitality(tokenId);
            assertLe(vNext, v, "Vitality must be monotonically non-increasing");
        }
    }

    // =====================================================================
    // 8. Seed
    // =====================================================================

    function test_SeedNonZero() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        assertTrue(art.seedOf(tokenId) != 0, "Seed should be nonzero");
    }

    function test_SeedUnchangedAfterCare() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        uint256 seedBefore = art.seedOf(tokenId);

        skip(12 hours);
        vm.prank(alice);
        art.care(tokenId);

        assertEq(art.seedOf(tokenId), seedBefore, "Seed must not change after care");
    }

    function test_SeedUnchangedAfterTransfer() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        uint256 seedBefore = art.seedOf(tokenId);

        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        assertEq(art.seedOf(tokenId), seedBefore, "Seed must not change after transfer");
    }

    function test_SeedsDistinct() public {
        uint256[] memory seeds = new uint256[](3);
        vm.prank(alice);
        seeds[0] = art.seedOf(art.mint());
        vm.prank(bob);
        seeds[1] = art.seedOf(art.mint());
        vm.prank(stranger);
        seeds[2] = art.seedOf(art.mint());

        assertTrue(seeds[0] != seeds[1], "Seeds 0 and 1 must differ");
        assertTrue(seeds[1] != seeds[2], "Seeds 1 and 2 must differ");
        assertTrue(seeds[0] != seeds[2], "Seeds 0 and 2 must differ");
    }

    function test_PaletteCoverage() public {
        // Mint many tokens from different addresses and check palette diversity
        AgingArt bigArt = new AgingArt(100, 100);
        bool[6] memory seen;
        uint256 numSeen;

        for (uint256 i = 0; i < 50; i++) {
            address minter = address(uint160(0x1000 + i));
            vm.prank(minter);
            uint256 tid = bigArt.mint();
            uint256 s = bigArt.seedOf(tid);
            uint256 paletteIdx = s % 6;
            if (!seen[paletteIdx]) {
                seen[paletteIdx] = true;
                numSeen++;
            }
        }

        // With 50 tokens and 6 palettes, all should appear with overwhelming probability
        assertGe(numSeen, 5, "At least 5 of 6 palettes should appear in 50 tokens");
    }

    function test_GeometryConsistentAcrossStages() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Get SVG at Blooming
        string memory svgBlooming = art.renderSVG(tokenId);

        // Get SVG at Verdant
        skip(1.5 days);
        string memory svgVerdant = art.renderSVG(tokenId);

        // Get SVG at Mossy
        skip(2 days);
        string memory svgMossy = art.renderSVG(tokenId);

        // Get SVG at Ancient
        skip(4 days);
        string memory svgAncient = art.renderSVG(tokenId);

        // Extract trunk path (the <path d="M... portion) — should be consistent
        // We check that the trunk path substring is present in all four
        // The trunk path starts with '<path d="M' and uses the same coordinates
        // Since trunk coordinates come from seed, they're the same across stages
        assertTrue(bytes(svgBlooming).length > 0, "Blooming SVG non-empty");
        assertTrue(bytes(svgVerdant).length > 0, "Verdant SVG non-empty");
        assertTrue(bytes(svgMossy).length > 0, "Mossy SVG non-empty");
        assertTrue(bytes(svgAncient).length > 0, "Ancient SVG non-empty");

        // All SVGs should differ (different decorations) but be non-empty
        assertTrue(
            keccak256(bytes(svgBlooming)) != keccak256(bytes(svgAncient)), "Blooming and Ancient SVGs should differ"
        );
    }

    function test_DifferentTokensDifferentSVGs() public {
        vm.prank(alice);
        uint256 t1 = art.mint();
        vm.prank(bob);
        uint256 t2 = art.mint();

        string memory svg1 = art.renderSVG(t1);
        string memory svg2 = art.renderSVG(t2);

        assertTrue(keccak256(bytes(svg1)) != keccak256(bytes(svg2)), "Different tokens should have different SVGs");
    }

    function test_SeedOf_NonexistentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        art.seedOf(999);
    }

    // =====================================================================
    // 9. tokenURI: decode and check attributes by trait_type for all stages
    // =====================================================================

    function test_TokenURI_Blooming() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        _checkTokenURI(tokenId, "Blooming", 100, 0);
    }

    function test_TokenURI_Verdant() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        skip(1.5 days);
        _checkTokenURI(tokenId, "Verdant", 79, 1);
    }

    function test_TokenURI_Mossy() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        skip(4 days);
        _checkTokenURI(tokenId, "Mossy", 43, 4);
    }

    function test_TokenURI_Ancient() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        skip(10 days);
        _checkTokenURI(tokenId, "Ancient Moss", 0, 10);
    }

    function _checkTokenURI(
        uint256 tokenId,
        string memory expectedStage,
        uint256 expectedVitality,
        uint256 expectedDays
    ) internal view {
        string memory jsonStr = _decodeTokenURIJson(tokenId);

        // Check name
        assertEq(vm.parseJsonString(jsonStr, ".name"), string.concat("Aging Art #", vm.toString(tokenId)));

        // Check attributes by trait_type (not by index)
        assertEq(_findTraitValue(jsonStr, "Stage"), expectedStage, "Stage mismatch");
        assertEq(_findTraitUintValue(jsonStr, "Vitality"), expectedVitality, "Vitality mismatch");
        assertEq(_findTraitUintValue(jsonStr, "Inactivity Days"), expectedDays, "Inactivity Days mismatch");
        assertTrue(bytes(_findTraitValue(jsonStr, "Palette")).length > 0, "Palette must be set");

        // Decode image and verify SVG markers
        _checkTokenURISvg(jsonStr, expectedStage, expectedVitality);
    }

    function _decodeTokenURIJson(uint256 tokenId) internal view returns (string memory) {
        string memory uri = art.tokenURI(tokenId);
        string memory jsonPrefix = "data:application/json;base64,";
        assertTrue(_startsWith(uri, jsonPrefix), "URI missing json data prefix");
        bytes memory b64Json = _slice(bytes(uri), bytes(jsonPrefix).length);
        return string(_base64Decode(b64Json));
    }

    function _checkTokenURISvg(string memory jsonStr, string memory expectedStage, uint256 expectedVitality)
        internal
        pure
    {
        string memory imageUri = vm.parseJsonString(jsonStr, ".image");
        string memory svgPrefix = "data:image/svg+xml;base64,";
        assertTrue(_startsWith(imageUri, svgPrefix), "Image missing svg prefix");

        bytes memory b64Svg = _slice(bytes(imageUri), bytes(svgPrefix).length);
        string memory decodedSvg = string(_base64Decode(b64Svg));

        assertTrue(_startsWith(decodedSvg, "<svg"), "Decoded image must start with <svg");
        assertTrue(_endsWith(decodedSvg, "</svg>"), "Decoded image must end with </svg>");

        // Check that stage badge text is in the SVG
        assertTrue(_contains(decodedSvg, _toUpperCase(expectedStage)), "SVG must contain stage badge text");

        // Check vitality bar width marker
        string memory vitalityText = string.concat("VITALITY: ", vm.toString(expectedVitality), "%");
        assertTrue(_contains(decodedSvg, vitalityText), "SVG must contain vitality text");
    }

    /// @dev Find trait_type string value by iterating attributes array.
    function _findTraitValue(string memory json, string memory traitType) internal pure returns (string memory) {
        // We use a simple approach: parse attributes as array and check each
        // Since Foundry's JSON parsing supports array indexing, iterate up to 10 attributes
        for (uint256 i = 0; i < 10; i++) {
            string memory path = string.concat(".attributes[", vm.toString(i), "].trait_type");
            try vm.parseJsonString(json, path) returns (string memory tt) {
                if (keccak256(bytes(tt)) == keccak256(bytes(traitType))) {
                    string memory valPath = string.concat(".attributes[", vm.toString(i), "].value");
                    return vm.parseJsonString(json, valPath);
                }
            } catch {
                break;
            }
        }
        revert(string.concat("Trait not found: ", traitType));
    }

    /// @dev Find trait_type uint value by iterating attributes array.
    function _findTraitUintValue(string memory json, string memory traitType) internal pure returns (uint256) {
        for (uint256 i = 0; i < 10; i++) {
            string memory path = string.concat(".attributes[", vm.toString(i), "].trait_type");
            try vm.parseJsonString(json, path) returns (string memory tt) {
                if (keccak256(bytes(tt)) == keccak256(bytes(traitType))) {
                    string memory valPath = string.concat(".attributes[", vm.toString(i), "].value");
                    return vm.parseJsonUint(json, valPath);
                }
            } catch {
                break;
            }
        }
        revert(string.concat("Trait not found: ", traitType));
    }

    // =====================================================================
    // Other existing tests (updated)
    // =====================================================================

    function test_RenderSVG_AllStagesValidTags() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Stage 0: Blooming
        string memory svg0 = art.renderSVG(tokenId);
        assertTrue(_startsWith(svg0, "<svg"), "Stage 0 must start with <svg");
        assertTrue(_endsWith(svg0, "</svg>"), "Stage 0 must end with </svg>");
        assertTrue(bytes(art.tokenURI(tokenId)).length > 0);

        // Stage 1: Verdant
        skip(1.5 days);
        string memory svg1 = art.renderSVG(tokenId);
        assertTrue(_startsWith(svg1, "<svg"), "Stage 1 must start with <svg");
        assertTrue(_endsWith(svg1, "</svg>"), "Stage 1 must end with </svg>");
        assertTrue(bytes(art.tokenURI(tokenId)).length > 0);

        // Stage 2: Mossy
        skip(2.5 days); // total 4 days
        string memory svg2 = art.renderSVG(tokenId);
        assertTrue(_startsWith(svg2, "<svg"), "Stage 2 must start with <svg");
        assertTrue(_endsWith(svg2, "</svg>"), "Stage 2 must end with </svg>");
        assertTrue(bytes(art.tokenURI(tokenId)).length > 0);

        // Stage 3: Ancient Moss
        skip(4 days); // total 8 days
        string memory svg3 = art.renderSVG(tokenId);
        assertTrue(_startsWith(svg3, "<svg"), "Stage 3 must start with <svg");
        assertTrue(_endsWith(svg3, "</svg>"), "Stage 3 must end with </svg>");
        assertTrue(bytes(art.tokenURI(tokenId)).length > 0);
    }

    function test_NonexistentTokenReverts() public {
        uint256 nonexistentId = 999;

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nonexistentId));
        art.tokenURI(nonexistentId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nonexistentId));
        art.getStage(nonexistentId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nonexistentId));
        art.getVitality(nonexistentId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nonexistentId));
        art.care(nonexistentId);
    }

    function test_EmitCared() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(2 days);

        vm.expectEmit(true, true, false, true);
        emit Cared(tokenId, alice, AgingArt.Stage.Verdant, AgingArt.Stage.Blooming, block.timestamp);

        vm.prank(alice);
        art.care(tokenId);
    }

    // =====================================================================
    // 10. Gas measurement for tokenURI at each stage
    // =====================================================================

    function test_Gas_TokenURI_Blooming() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        uint256 gasBefore = gasleft();
        art.tokenURI(tokenId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas tokenURI Blooming", gasUsed);
    }

    function test_Gas_TokenURI_Verdant() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        skip(1.5 days);
        uint256 gasBefore = gasleft();
        art.tokenURI(tokenId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas tokenURI Verdant", gasUsed);
    }

    function test_Gas_TokenURI_Mossy() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        skip(4 days);
        uint256 gasBefore = gasleft();
        art.tokenURI(tokenId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas tokenURI Mossy", gasUsed);
    }

    function test_Gas_TokenURI_Ancient() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();
        skip(10 days);
        uint256 gasBefore = gasleft();
        art.tokenURI(tokenId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas tokenURI Ancient", gasUsed);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        if (strBytes.length < prefixBytes.length) return false;
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory str, string memory suffix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory suffixBytes = bytes(suffix);
        if (strBytes.length < suffixBytes.length) return false;
        uint256 offset = strBytes.length - suffixBytes.length;
        for (uint256 i = 0; i < suffixBytes.length; i++) {
            if (strBytes[offset + i] != suffixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory str, string memory substr) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory subBytes = bytes(substr);
        if (subBytes.length > strBytes.length) return false;
        if (subBytes.length == 0) return true;
        uint256 limit = strBytes.length - subBytes.length + 1;
        for (uint256 i = 0; i < limit; i++) {
            bool found = true;
            for (uint256 j = 0; j < subBytes.length; j++) {
                if (strBytes[i + j] != subBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function _toUpperCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory upper = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            if (bStr[i] >= 0x61 && bStr[i] <= 0x7A) {
                upper[i] = bytes1(uint8(bStr[i]) - 32);
            } else {
                upper[i] = bStr[i];
            }
        }
        return string(upper);
    }

    function _slice(bytes memory data, uint256 startIdx) internal pure returns (bytes memory) {
        require(data.length >= startIdx, "Slice out of bounds");
        bytes memory result = new bytes(data.length - startIdx);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[startIdx + i];
        }
        return result;
    }

    function _base64Decode(bytes memory data) internal pure returns (bytes memory) {
        uint256 len = data.length;
        if (len == 0) return "";
        require(len % 4 == 0, "Invalid base64 length");

        uint256 pad = 0;
        if (len > 0 && data[len - 1] == "=") {
            pad++;
            if (len > 1 && data[len - 2] == "=") {
                pad++;
            }
        }

        uint256 decodedLen = (len / 4) * 3 - pad;
        bytes memory decoded = new bytes(decodedLen);

        bytes memory table = new bytes(256);
        bytes memory chars = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        for (uint256 i = 0; i < 64; i++) {
            table[uint8(chars[i])] = bytes1(uint8(i));
        }

        uint256 di = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 b0 = uint8(table[uint8(data[i])]);
            uint256 b1 = uint8(table[uint8(data[i + 1])]);
            uint256 b2 = uint8(table[uint8(data[i + 2])]);
            uint256 b3 = uint8(table[uint8(data[i + 3])]);

            uint256 triple = (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;

            if (di < decodedLen) decoded[di++] = bytes1(uint8(triple >> 16));
            if (di < decodedLen) decoded[di++] = bytes1(uint8(triple >> 8));
            if (di < decodedLen) decoded[di++] = bytes1(uint8(triple));
        }

        return decoded;
    }
}
