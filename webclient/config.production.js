// Production config, copied to config.js by the Railway build (see railway.json).
// Local dev keeps its own gitignored config.js; this file is the deployed one — fill in the
// real deployer/distributor addresses once the contracts are live on a public network.
window.STICKY_CONFIG = {
  rpcUrl: "",
  ensRpc: "https://ethereum-rpc.publicnode.com",
  deployer: "",
  projectId: undefined,
  fromBlock: "earliest",
  distributor: "",
  pockets: "",
  autoStickAdapter: "",
  chains: {
    // "1": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
    // "10": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
    // "8453": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
    // "42161": { rpcUrl: "https://…", deployer: "0x…", autoStickAdapter: "0x…" },
  },
};
