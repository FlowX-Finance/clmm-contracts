require("dotenv").config({});
const { execSync } = require("child_process");

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

async function upgrade() {
  const { modules, dependencies, digest } = JSON.parse(
    execSync("sui move build --dump-bytecode-as-base64", {
      encoding: "utf-8",
    })
  );

  const transactionBlock = new TransactionBlock();

  const upgradeTicket = transactionBlock.moveCall({
    target: "0x2::package::authorize_upgrade",
    arguments: [
      transactionBlock.object(process.env.UPGRADE_CAP_OBJECT_ID),
      transactionBlock.pure(0),
      transactionBlock.pure(digest),
    ],
  });

  const upgradeReceipt = transactionBlock.upgrade({
    modules,
    dependencies,
    packageId: process.env.PACKAGE_ID,
    ticket: upgradeTicket,
  });

  transactionBlock.moveCall({
    target: "0x2::package::commit_upgrade",
    arguments: [
      transactionBlock.object(process.env.UPGRADE_CAP_OBJECT_ID),
      upgradeReceipt,
    ],
  });

  const txResponse = await provider.signAndExecuteTransactionBlock({
    transactionBlock,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  const packageId = txResponse.objectChanges.find(
    (obj) => obj.type === "published"
  ).packageId;
  console.info(
    `Upgrading the package successfully at ${packageId}, tx: ${txResponse.digest}`
  );
}

(async function () {
  await upgrade();
})();
