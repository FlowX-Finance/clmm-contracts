require("dotenv").config({});

const { hexToBytes } = require("@noble/hashes/utils");
const { TransactionBlock } = require("@mysten/sui.js/transactions");
const { SuiClient } = require("@mysten/sui.js/client");
const { Ed25519Keypair } = require("@mysten/sui.js/keypairs/ed25519");
const {
  decodeSuiPrivateKey,
  SUI_PRIVATE_KEY_PREFIX,
} = require("@mysten/sui.js/cryptography");

const provider = new SuiClient({
  url: process.env.JSON_RPC_ENDPOINT,
});

const signer = Ed25519Keypair.fromSecretKey(
  process.env.PRIVATE_KEY.startsWith(SUI_PRIVATE_KEY_PREFIX)
    ? decodeSuiPrivateKey(process.env.PRIVATE_KEY).secretKey
    : hexToBytes(process.env.PRIVATE_KEY.replace("0x", ""))
);

async function grantPoolManager(poolManagerAddr) {
  const transactionBlock = new TransactionBlock();

  transactionBlock.moveCall({
    target: `${process.env.PACKAGE_ID}::pool_manager::grant_pool_manager`,
    arguments: [
      transactionBlock.object(process.env.ADMIN_CAP_OBJECT_ID),
      transactionBlock.object(process.env.POOL_REGISTRY_OBJECT_ID),
      transactionBlock.pure.address(poolManagerAddr),
      transactionBlock.object(process.env.VERSIONED_OBJECT_ID),
    ],
  });

  const txResponse = await provider.signAndExecuteTransactionBlock({
    transactionBlock,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  console.info(`Migrating the package successfully tx: ${txResponse.digest}`);
}

(async function () {
  await grantPoolManager(process.env.POOL_MANAGER_ADDRESS);
})();
