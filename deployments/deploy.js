require("dotenv").config({});
const { execSync } = require("child_process");
const { SuiClient } = require("@mysten/sui.js/client");
const {
  decodeSuiPrivateKey,
  SUI_PRIVATE_KEY_PREFIX,
} = require("@mysten/sui.js/cryptography");
const { Ed25519Keypair } = require("@mysten/sui.js/keypairs/ed25519");
const { TransactionBlock } = require("@mysten/sui.js/transactions");

const { hexToBytes } = require("@noble/hashes/utils");

const provider = new SuiClient({
  url: process.env.JSON_RPC_ENDPOINT,
});

const signer = Ed25519Keypair.fromSecretKey(
  process.env.PRIVATE_KEY.startsWith(SUI_PRIVATE_KEY_PREFIX)
    ? decodeSuiPrivateKey(process.env.PRIVATE_KEY).secretKey
    : hexToBytes(process.env.PRIVATE_KEY.replace("0x", ""))
);
const signerAddress = signer.toSuiAddress();

async function deploy() {
  console.info("Signer: ", signerAddress);
  const { modules, dependencies } = JSON.parse(
    execSync("sui move build --dump-bytecode-as-base64", {
      encoding: "utf-8",
    })
  );

  const txb = new TransactionBlock();
  const res = txb.publish({
    modules,
    dependencies,
  });

  txb.transferObjects([res], txb.pure(signerAddress));
  const txResponse = await provider.signAndExecuteTransactionBlock({
    transactionBlock: txb,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  const packageId = txResponse.objectChanges.find(
    (obj) => obj.type === "published"
  ).packageId;
  console.info(
    `Publishing the package successfully at ${packageId}, tx: ${txResponse.digest}`
  );
}

(async function () {
  await deploy();
})();
