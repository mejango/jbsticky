// Copy to config.js and fill in. All fields optional.
window.STICKY_CONFIG = {
  rpcUrl: "http://localhost:8545",
  ensRpc: "https://ethereum-rpc.publicnode.com", // optional mainnet RPC for reverse ENS names
  deployer: "",   // JBStreaksDeployer address
  account: "",    // account to act as (anvil auto-impersonation) — or connect a browser wallet
  projectId: undefined, // auto-open this streaks project
  fromBlock: "earliest", // log scan start for project discovery
  distributor: "", // JBTokenDistributor for streaks rewards
  pockets: "", // JBStreaksRewardPockets factory for cross-chain rewards
  autoStickAdapter: "", // JBStickyAutoStick adapter — permanently pre-approved at launch when configured
  // Per-chain deployment metadata powers multi-chain creation. Add an entry for every supported launch chain.
  chains: {
    // "1": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
    // "10": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
    // "8453": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
    // "42161": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
  },
  projectChainOverrides: undefined, // optional { "25": [1, 10, 8453, 42161] } for older projects without metadata
  projectNameOverrides: undefined, // optional { "25": "Artizen" } project-name overrides
  demoHomeStickiest: undefined, // optional local-only mock sticky project cards
  demoHomeAirdrops: undefined, // optional local-only mock airdrop activity
  demoChartHistory: undefined, // optional local-only [{ daysAgo, streaks, locked }] chart snapshots
};
