// Local explicit demo configuration. For live production use build-config.py;
// see .env.example for validated deployment addresses, RPCs, and per-chain options.
// All values in this file are public. Demo mode does not sign or send transactions.
window.STICKY_CONFIG = {
  "demoMode": true,
  "defaultChainId": 1,
  "rpcUrl": "https://ethereum-rpc.publicnode.com",
  "ensRpc": "https://ethereum-rpc.publicnode.com",
  "relayrUrl": "https://api.relayr.ba5ed.com",
  "deployer": "",
  "distributor": "",
  "pockets": "",
  "autoStickAdapter": "",
  "projectId": null,
  "fromBlock": "earliest",
  "chains": {}
};
