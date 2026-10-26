// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgingArt} from "../src/AgingArt.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract NonReceiverContract {
    AgingArt public art;

    constructor(AgingArt _art) {
        art = _art;
    }

    function attemptMint() external returns (uint256) {
        return art.mint();
    }
}

contract AgingArtTest is Test {
    AgingArt public art;

    address public alice;
    address public bob;
    address public operator;
    address public approved;
    address public stranger;

    // Events mirrored for vm.expectEmit
    event Minted(uint256 indexed tokenId, address indexed recipient);
    event Cared(uint256 indexed tokenId, address indexed owner, uint256 timestamp);

    function setUp() public {
        art = new AgingArt();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        operator = makeAddr("operator");
        approved = makeAddr("approved");
        stranger = makeAddr("stranger");
    }

    /**
     * @notice Requirement 1:
     * Stage boundaries and exact hardcoded vitality values.
     */
    function test_StageBoundaries() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // 1. Immediately at mint (0 elapsed)
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);

        // 2. Boundary: 1 days - 1 second -> Blooming, vitality 85
        skip(1 days - 1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 85);

        // 3. Boundary: 1 days exact -> Verdant, vitality 85
        skip(1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        assertEq(art.getVitality(tokenId), 85);

        // 4. Boundary: 3 days - 1 second -> Verdant, vitality 57
        skip(2 days - 1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        assertEq(art.getVitality(tokenId), 57);

        // 5. Boundary: 3 days exact -> Mossy, vitality 57
        skip(1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertEq(art.getVitality(tokenId), 57);

        // 6. Boundary: 7 days - 1 second -> Mossy, vitality 0
        skip(4 days - 1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertEq(art.getVitality(tokenId), 0);

        // 7. Boundary: 7 days exact -> Ancient Moss, vitality 0
        skip(1);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));
        assertEq(art.getVitality(tokenId), 0);

        // 8. Beyond 7 days -> Ancient Moss, vitality 0
        skip(7 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));
        assertEq(art.getVitality(tokenId), 0);
    }

    /**
     * @notice Requirement 2:
     * Check that renderSVG starts with "<svg" and ends with "</svg>" for all 4 stages.
     */
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

    /**
     * @notice Requirement 3:
     * Fuzz: stage checked against thresholds, assertLe(v, 100), monotonicity.
     */
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

        // Monotonic non-increasing check
        if (elapsed < 3650 days) {
            skip(1 hours);
            uint256 vNext = art.getVitality(tokenId);
            assertLe(vNext, v, "Vitality must be monotonically non-increasing");
        }
    }

    /**
     * @notice Requirement 4:
     * tokenURI test: attributes[0].value == "Blooming", attributes[1].value == 100,
     * decode image and verify it is valid SVG.
     */
    function test_TokenURI_AttributesAndDecodedImage() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        string memory uri = art.tokenURI(tokenId);
        string memory jsonPrefix = "data:application/json;base64,";
        assertTrue(_startsWith(uri, jsonPrefix), "URI missing json data prefix");

        bytes memory b64Json = _slice(bytes(uri), bytes(jsonPrefix).length);
        string memory jsonStr = string(_base64Decode(b64Json));

        // Check name
        string memory name = vm.parseJsonString(jsonStr, ".name");
        assertEq(name, "Aging Art #1");

        // Check attributes values
        string memory stageAttr = vm.parseJsonString(jsonStr, ".attributes[0].value");
        assertEq(stageAttr, "Blooming", "attributes[0].value must be Blooming");

        uint256 vitalityAttr = vm.parseJsonUint(jsonStr, ".attributes[1].value");
        assertEq(vitalityAttr, 100, "attributes[1].value must be 100");

        // Decode image SVG
        string memory imageUri = vm.parseJsonString(jsonStr, ".image");
        string memory svgPrefix = "data:image/svg+xml;base64,";
        assertTrue(_startsWith(imageUri, svgPrefix), "Image missing svg prefix");

        bytes memory b64Svg = _slice(bytes(imageUri), bytes(svgPrefix).length);
        string memory decodedSvg = string(_base64Decode(b64Svg));

        assertTrue(_startsWith(decodedSvg, "<svg"), "Decoded image must start with <svg");
        assertTrue(_endsWith(decodedSvg, "</svg>"), "Decoded image must end with </svg>");
    }

    /**
     * @notice Requirement 5:
     * - Mint from contract without onERC721Received reverts.
     * - Minted and Cared events are emitted.
     * - approved cannot care after transferFrom.
     * - approved for token 1 cannot care token 2.
     */
    function test_MintFromContractWithoutReceiverReverts() public {
        NonReceiverContract nonReceiver = new NonReceiverContract(art);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(nonReceiver)));
        nonReceiver.attemptMint();
    }

    function test_EmitMinted() public {
        vm.expectEmit(true, true, false, false);
        emit Minted(1, alice);

        vm.prank(alice);
        art.mint();
    }

    function test_EmitCared() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(2 days);

        vm.expectEmit(true, true, false, true);
        emit Cared(tokenId, alice, block.timestamp);

        vm.prank(alice);
        art.care(tokenId);
    }

    function test_ApprovedCannotCareAfterTransferFrom() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Alice approves 'approved' address
        vm.prank(alice);
        art.approve(approved, tokenId);

        // Alice transfers token to Bob
        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        // Token is now owned by Bob; approval was cleared
        skip(2 days);
        vm.prank(approved);
        vm.expectRevert("Not authorized");
        art.care(tokenId);
    }

    function test_ApprovedForToken1CannotCareToken2() public {
        vm.prank(alice);
        uint256 token1 = art.mint();

        vm.prank(alice);
        uint256 token2 = art.mint();

        // Alice approves for token 1 only
        vm.prank(alice);
        art.approve(approved, token1);

        skip(2 days);

        // Approved address can care token 1
        vm.prank(approved);
        art.care(token1);
        assertEq(uint8(art.getStage(token1)), uint8(AgingArt.Stage.Blooming));

        // Approved address CANNOT care token 2
        vm.prank(approved);
        vm.expectRevert("Not authorized");
        art.care(token2);
    }

    /**
     * @notice Care access control tests
     */
    function test_Care_Owner() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(10 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));

        vm.prank(alice);
        art.care(tokenId);

        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
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

        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
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

        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_Care_StrangerReverts() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);

        vm.prank(stranger);
        vm.expectRevert("Not authorized");
        art.care(tokenId);
    }

    /**
     * @notice Transfers reset timer
     */
    function test_TransferResetsTimer() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));

        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        assertEq(art.ownerOf(tokenId), bob);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_TransferToSelfResetsTimer() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        skip(5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));

        vm.prank(alice);
        art.transferFrom(alice, alice, tokenId);

        assertEq(art.ownerOf(tokenId), alice);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    /**
     * @notice Nonexistent token reverts
     */
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

    // Helper functions
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
