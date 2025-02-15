/*
 * Spends a batch of leaves by posting a withdrawal proof. See verif-manager 
 * circuits for more context on the SNARK proof. Current implementation 
 * reconstructs the deposit Merkle tree on every execution to generate the 
 * inclusion arguments. The total values of the leaves will be sent to the 
 * sender's (manager's) account.
 */

import dotenv from "dotenv";
dotenv.config();

// @ts-ignore
import { buildPoseidon } from "circomlibjs";
import { ethers } from "ethers";
import fs from "fs";
// @ts-ignore
import { groth16 } from "snarkjs";
import { NOTHING_UP_MY_SLEEVE, IncrementalQuinTree } from "maci-crypto";
// @ts-ignore
import { PrivateKey } from "babyjubjub";

import {
    Groth16Proof,
    Groth16ProofCalldata,
    WithdrawPubSignals,
} from "./types";
import Leaf from "./Leaf";
import Utils from "./utils";

// Total amount of ETH to withdraw 
const WITHDRAW_AMOUNT_ETH = "0.15";

// Unspent leaves to use for withdrawal. Indexed relative to target treasury's
// leaves. Example: specifying 1 and 2 in the array below may map to indices 15 
// and 40 when listing all leaves in the tree
const LEAF_INDICES: number[] = [0, 1];

// Max number of leaves that can be withdrawn at a time. Must be the same value
// set in the circuit. Default value is 5 for testing, but a 1000 leaves should
// still only take under 100s with a Groth16 prover. 
const N_MAX_WITHDRAW: number = 5;

// Depth of Merkle tree
const TREE_DEPTH: number = 32;

// Point to the outputs of the setup() step for the SNARK 
const PROV_KEY: string = "../circuits/verif-manager.zkey";
const VERIF_KEY: string = "../circuits/verif-manager.vkey.json";
const WASM: string = "../circuits/verif-manager.wasm";

const signer: ethers.Wallet = new ethers.Wallet(
    <string>process.env.MANAGER_ETH_PRIVKEY,
    new ethers.providers.JsonRpcProvider(process.env.RPC_URL)
);
const privateTreasury: ethers.Contract = new ethers.Contract(
    <string>process.env.CONTRACT_ADDR,
    require(<string>process.env.CONTRACT_ABI_PATH).abi,
    signer
);

/*
 * Queries contract for all leaves ever stored. Uses emitted NewLeaf event.
 * Hashes leaves using poseidon hash.
 */
async function getDepositHistory(poseidon: any): Promise<[Leaf[], BigInt[]]> {
    console.log("== Fetching deposit history");
    const newLeafEvents: ethers.Event[] = await privateTreasury.queryFilter(
        privateTreasury.filters.NewLeaf()
    );
    const leafHistory: Leaf[] = newLeafEvents.map((e) =>
        Leaf.fromSol(e.args?.lf)
    );
    const leafHashes: BigInt[] = leafHistory.map((lf) =>
        lf.poseidonHash(poseidon)
    );
    console.log(`- Retrieved ${leafHashes.length} leaves`);
    console.log("==");
    return [leafHistory, leafHashes];
}

/*
 * Finds indices of owned leaves, i.e. the treasury private key at hand
 * satisfies P * α = G.
 */
function checkLeafOwnership(leafHistory: Leaf[]): number[] {
    console.log("== Checking leaves for ownership");
    const owned: number[] = leafHistory.reduce(
        (a: number[], lf: Leaf, i: number) => {
            const isOwned: boolean = lf.checkQDerivation(
                new PrivateKey(process.env.TREASURY_PRIVKEY)
            );
            if (isOwned) a.push(i);
            return a;
        },
        []
    );
    console.log(`- Found ${owned.length} leaves recoverable by the privKey.`);
    console.log("==");
    return owned;
}

/*
 * Generates groth16 proof to batch withdraw deposits.
 *
 * @dev Currently hacky padding by repeating the first leaf until
 *      N_MAX_WITHDRAW length. Ideally pad with 0 initialized elements and
 *      figure out conditional in circuit.
 */
async function genGroth16Proof(
    leaves: Leaf[],
    leafIndices: number[],
    root: BigInt,
    treasuryPriv: string,
    inclusionProofs: any[]
): Promise<[Groth16Proof, WithdrawPubSignals]> {
    console.log("== Generating SNARK proof");
    const leavesBase10 = leaves.map((lf) => lf.base10());
    const [paddedLeaves, paddedInclusionProofs, paddedLeafIndices] =
        Utils.padCircuitInputs(
            N_MAX_WITHDRAW,
            leafIndices,
            leavesBase10,
            inclusionProofs
        );
    const { proof, publicSignals } = await groth16.fullProve(
        {
            v: paddedLeaves.map((lfBase10) => lfBase10.v),
            root: root.toString(),
            leafIndex: paddedLeafIndices,
            P: paddedLeaves.map((lfBase10) => lfBase10.P),
            Q: paddedLeaves.map((lfBase10) => lfBase10.Q),
            treasuryPriv: treasuryPriv,
            pathIndex: paddedInclusionProofs.map((prf) => prf.indices),
            pathElements: paddedInclusionProofs.map((prf) => prf.pathElements),
        },
        WASM,
        PROV_KEY
    );
    console.log("- Success");
    console.log("==");
    return [proof, publicSignals];
}

/*
 * Ensures proof verifies client-side with snarkjs before posting on-chain.
 */
async function proveSanityCheck(
    prf: Groth16Proof,
    pubSigs: WithdrawPubSignals
) {
    console.log("== Running sanity check, verifying SNARK proof client-side");
    const vKey = JSON.parse(fs.readFileSync(VERIF_KEY, "utf8"));
    const res = await groth16.verify(vKey, pubSigs, prf);
    if (res === true) {
        console.log("- Verification OK");
    } else {
        console.log("- Invalid proof");
    }
    console.log("==");
}

/*
 * Posts the zkSNARK proof on-chain and logs the increase in the manager's
 * balance. Uses the P & Q of the last leaf in the batch for the computational
 * diffie-hellman problem of the change leaf. Need the 60s timeout call for
 * non-local blockchains that don't have instant finality.
 */
async function sendProofTx(
    targetLeaves: Leaf[],
    prf: Groth16Proof,
    pubSigs: WithdrawPubSignals
) {
    console.log("== Sending tx with withdrawal proof");
    const formattedProof: Groth16ProofCalldata =
        await Utils.exportCallDataGroth16(prf, pubSigs);
    console.log("Proof:", formattedProof);
    const result = await privateTreasury.withdraw(
        ethers.utils.parseEther(WITHDRAW_AMOUNT_ETH),
        ...targetLeaves[targetLeaves.length - 1].exportCallData(),
        formattedProof.a,
        formattedProof.b,
        formattedProof.c,
        formattedProof.input
    );
    console.log("- tx:", result);
    console.log("==");
}

/*
 * Reconstructs Merkle tree of deposits client side for inclusion proof
 * generation. Future iterations should cache the tree and update as NewLeaf
 * events are emitted. 
 */
async function reconstructMerkleTree(
    leafHashes: BigInt[]
): Promise<IncrementalQuinTree> {
    console.log("== Reconstructing Merkle tree");
    let tree: IncrementalQuinTree = new IncrementalQuinTree(
        TREE_DEPTH,
        NOTHING_UP_MY_SLEEVE,
        2
    );
    leafHashes.forEach((lh: BigInt) => {
        tree.insert(lh);
    });
    console.log("- Root:", tree.root);
    console.log(
        "- Same as root stored on contract?",
        tree.root === BigInt(await privateTreasury.root())
    );
    console.log("==");
    return tree;
}

/*
 * Generate a Merkle inclusion proof for each target index.
 */
function genMerkleProofs(tree: IncrementalQuinTree, targetIndices: number[]) {
    console.log("== Generating Merkle Proofs");
    const prfs = targetIndices.map((ownedIdx) => tree.genMerklePath(ownedIdx));
    console.log(prfs);
    console.log("==");
    return prfs
}

(async () => {
    const poseidon = await buildPoseidon();
    const [leafHistory, leafHashes] = await getDepositHistory(poseidon);

    const ownedIndices = checkLeafOwnership(leafHistory);
    const targetIndices = LEAF_INDICES.map((idx) => ownedIndices[idx]);
    const targetLeaves = targetIndices.map((ownedIdx) => leafHistory[ownedIdx]);

    const tree = await reconstructMerkleTree(leafHashes);
    const merkleProofs = genMerkleProofs(tree, targetIndices);

    const [proof, publicSignals] = await genGroth16Proof(
        targetLeaves,
        targetIndices,
        tree.root,
        <string>process.env.TREASURY_PRIVKEY,
        merkleProofs
    );
    await proveSanityCheck(proof, publicSignals);
    await sendProofTx(targetLeaves, proof, publicSignals);

    process.exit(0);
})();
