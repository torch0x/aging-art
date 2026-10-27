// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgingArt} from "../src/AgingArt.sol";

contract ExportSVGScript is Script {
    function run() external {
        AgingArt art = new AgingArt(1000, 3);

        vm.createDir("svg", true);

        uint256 numTokens = 8;

        // Mint tokens from different addresses for different seeds
        uint256[] memory tokenIds = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            address user = address(uint160(0x1000 + i));
            vm.prank(user);
            tokenIds[i] = art.mint();
        }

        // Stage durations for warping
        uint256[4] memory stageWarps = [uint256(0), 1.5 days, 4 days, 10 days];
        string[4] memory stageNames = ["bloom", "verdant", "mossy", "ancient"];

        // For each token, export all 4 stages
        // We need to restore time between tokens, so we use vm.warp
        uint256 baseTime = block.timestamp;

        for (uint256 t = 0; t < numTokens; t++) {
            for (uint256 s = 0; s < 4; s++) {
                vm.warp(baseTime + stageWarps[s]);

                string memory svg = art.renderSVG(tokenIds[t]);
                string memory filename =
                    string.concat("svg/token", vm.toString(tokenIds[t]), "_", stageNames[s], ".svg");
                vm.writeFile(filename, svg);
            }
        }

        // Generate index.html contact sheet
        string memory html = string.concat(
            "<!DOCTYPE html><html><head><meta charset='utf-8'/>",
            "<title>AgingArt Gallery</title>",
            "<style>",
            "body{background:#111;color:#fff;font-family:monospace;padding:20px}",
            "h1{text-align:center}",
            ".grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;max-width:1600px;margin:0 auto}",
            ".cell{text-align:center}",
            ".cell img{width:100%;border:1px solid #333;border-radius:4px}",
            ".cell p{margin:4px 0;font-size:12px}",
            "</style></head><body>",
            "<h1>AgingArt - Visual Gallery</h1>",
            "<p style='text-align:center'>Rows: tokens (different seeds) | Columns: stages</p>"
        );

        for (uint256 t = 0; t < numTokens; t++) {
            html = string.concat(html, "<h3>Token #", vm.toString(tokenIds[t]), "</h3><div class='grid'>");
            for (uint256 s = 0; s < 4; s++) {
                string memory filename = string.concat("token", vm.toString(tokenIds[t]), "_", stageNames[s], ".svg");
                html = string.concat(
                    html, "<div class='cell'><img src='", filename, "'/><p>", stageNames[s], "</p></div>"
                );
            }
            html = string.concat(html, "</div>");
        }

        html = string.concat(html, "</body></html>");
        vm.writeFile("svg/index.html", html);

        console.log("Exported %d tokens x 4 stages + index.html", numTokens);
    }
}
