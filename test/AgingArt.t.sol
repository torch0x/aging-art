// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {AgingArt} from "../src/AgingArt.sol";

contract AgingArtTest is Test {
    AgingArt public art;
    address public alice = address(0x1111);
    address public bob = address(0x2222);

    function setUp() public {
        art = new AgingArt();
    }

    function test_Mint() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        assertEq(tokenId, 1);
        assertEq(art.ownerOf(tokenId), alice);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_AgingProcess() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // 1. Immediately after minting: Blooming
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);

        uint256 start = vm.getBlockTimestamp();

        // 2. Warp 1.5 days: Verdant
        vm.warp(start + 1.5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Verdant));
        assertTrue(art.getVitality(tokenId) < 100 && art.getVitality(tokenId) > 50);

        // 3. Warp to 4 days: Mossy
        vm.warp(start + 4 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));
        assertTrue(art.getVitality(tokenId) < 50 && art.getVitality(tokenId) > 0);

        // 4. Warp to 8 days: Ancient Moss
        vm.warp(start + 8 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));
        assertEq(art.getVitality(tokenId), 0);
    }

    function test_CareBringsBackToBloom() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        // Let it age for 10 days until completely covered in moss
        vm.warp(block.timestamp + 10 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Ancient));

        // Alice cares for the art
        vm.prank(alice);
        art.care(tokenId);

        // Restored to Blooming!
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_CareUnauthorizedReverts() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.warp(block.timestamp + 5 days);

        // Bob tries to care for Alice's token without permission
        vm.prank(bob);
        vm.expectRevert("Not authorized");
        art.care(tokenId);
    }

    function test_TransferRefreshesActivity() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        vm.warp(block.timestamp + 5 days);
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Mossy));

        // Alice transfers to Bob
        vm.prank(alice);
        art.transferFrom(alice, bob, tokenId);

        // Transferred token is refreshed for the new owner
        assertEq(uint8(art.getStage(tokenId)), uint8(AgingArt.Stage.Blooming));
        assertEq(art.getVitality(tokenId), 100);
    }

    function test_RenderSVGAndTokenURI() public {
        vm.prank(alice);
        uint256 tokenId = art.mint();

        string memory svg = art.renderSVG(tokenId);
        assertTrue(bytes(svg).length > 0);
        console.log("Blooming SVG: %s", svg);

        string memory uri = art.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0);
        console.log("Token URI prefix: %s", substring(uri, 0, 40));
    }

    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }
}

