# AgingArt

**Fully on-chain living ERC-721 generative art.** Left neglected, the artwork is overgrown by ancient moss. Nurtured with care, it blooms with vibrant life.

---

## Repository Structure

```text
aging-art/
├── src/
│   └── AgingArt.sol         # Core: ERC-721, aging logic, and on-chain SVG renderer
├── test/
│   └── AgingArt.t.sol       # Test suite: unit, boundary, auth, and fuzz tests
├── script/
│   └── ExportSVG.s.sol      # Tooling: multi-token SVG & HTML gallery exporter
├── svg/                     # Output: exported SVG assets and index.html gallery
└── foundry.toml             # Foundry configuration & L2 EVM target settings
```

---

## Mechanics

### 1. Stages of Aging
Every token ages based on elapsed inactivity (`block.timestamp - lastActionTimestamp`):

| Stage | Inactivity Threshold | Visual Traits | Vitality |
| :--- | :--- | :--- | :---: |
| **Blooming** | `< 1 day` | Vibrant flowers, golden cores, floating spores | 86% – 100% |
| **Verdant** | `1 – 3 days` | Lush foliage, healthy emerald canopy | 58% – 86% |
| **Mossy** | `3 – 7 days` | Spreading lichen, creeping moss clusters | 1% – 58% |
| **Ancient Moss** | `≥ 7 days` | Overgrown tendrils, dark lichen covering the monolith | 0% |

* **Vitality Score:** Computed using ceiling division; `vitality == 0` strictly if and only if the stage is `Ancient`.

### 2. Stepwise Care (`care()`)
* Nurturing the token raises it by **exactly one stage** (e.g. `Ancient` → `Mossy` → `Verdant` → `Blooming`).
* **Anchor Invariant:** Adjusts `lastActionTimestamp` to the target stage threshold without ever moving backward.
* **12h Cooldown:** Per-token cooldown (`CARE_COOLDOWN = 12 hours`).
* **Transfers:** Transfers do **not** reset the age timer or cooldown — the art carries its age and history to the new owner.

### 3. Generative Traits & Deterministic Seed
Each token derives an immutable visual `seed` at mint from `tokenId`, `msg.sender`, `blockhash`, and `block.chainid`:
* **Procedural Tree:** Unique trunk lean, 3–5 branching structure, and jittered branch endpoints.
* **Anchored Decor:** Moss, foliage, flowers, and dripping tendrils are anchored directly to computed branch coordinates.
* **6 Palettes:** Sakura, Coral, Lavender, Amber, Crimson, and Arctic.

### 4. Mint Policy
* **Free Mint:** Enforced hard caps via immutable `MAX_SUPPLY` and `MAX_PER_WALLET`.
* **Sybil-Resistant Tracking:** Wallet limits track lifetime mint count (`mintedBy`), preventing bypasses via token transfers.
* **CEI / Reentrancy Safe:** All state updates and counter increments precede `_safeMint`.

---

## Development

Built with [Foundry](https://getfoundry.sh/) and [OpenZeppelin Contracts v5](https://openzeppelin.com/contracts/).

### Prerequisites
* [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)

### Commands

```shell
# Compile contracts
forge build

# Run test suite (52 tests including fuzzing)
forge test

# Run tests with detailed execution traces
forge test -vvv

# Check code formatting
forge fmt --check

# Export SVG gallery across all stages + HTML contact sheet
forge script script/ExportSVG.s.sol
```

After running `ExportSVG.s.sol`, open `svg/index.html` in your browser to inspect the visual matrix of 8 distinct seeds across all 4 stages.

---

## License
MIT
