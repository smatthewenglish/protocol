import RPC from "../../utils/rpc"
import {contractId} from "../../utils/helpers"

import {ethers} from "hardhat"
import setupIntegrationTest from "../helpers/setupIntegrationTest"

import chai from "chai"
import {solidity} from "ethereum-waffle"
chai.use(solidity)

describe("checkpoint bonding state gas report", () => {
    let rpc
    let snapshotId

    let controller
    let bondingManager
    let roundsManager
    let token

    let transcoder
    let delegator

    const stake = 1000

    let signers

    before(async () => {
        rpc = new RPC(web3)
        signers = await ethers.getSigners()
        transcoder = signers[0]
        delegator = signers[1]

        const fixture = await setupIntegrationTest()
        controller = await ethers.getContractAt(
            "Controller",
            fixture.Controller.address
        )

        bondingManager = await ethers.getContractAt(
            "BondingManager",
            fixture.BondingManager.address
        )

        roundsManager = await ethers.getContractAt(
            "AdjustableRoundsManager",
            fixture.AdjustableRoundsManager.address
        )

        token = await ethers.getContractAt(
            "LivepeerToken",
            fixture.LivepeerToken.address
        )

        roundLength = await roundsManager.roundLength()

        await controller.unpause()

        // Register transcoder and delegator
        await token.transfer(transcoder.address, stake)
        await token.connect(transcoder).approve(bondingManager.address, stake)
        await bondingManager.connect(transcoder).bond(stake, transcoder.address)

        await token.transfer(delegator.address, stake)
        await token.connect(delegator).approve(bondingManager.address, stake)
        await bondingManager.connect(delegator).bond(stake, transcoder.address)

        // Fast forward to start of new round to lock in active set
        const roundLength = await roundsManager.roundLength()
        await roundsManager.mineBlocks(roundLength.toNumber())
        await roundsManager.initializeRound()

        // Deploy a new BondingCheckpoints contract so we can simulate a fresh deploy on existing BondingManager state
        const [, gitCommitHash] = await controller.getContractInfo(
            contractId("BondingCheckpoints")
        )
        const newBondingCheckpoints = await ethers
            .getContractFactory("BondingCheckpoints")
            .then(fac => fac.deploy(controller.address))
        await controller.setContractInfo(
            contractId("BondingCheckpoints"),
            newBondingCheckpoints.address,
            gitCommitHash
        )
    })

    beforeEach(async () => {
        snapshotId = await rpc.snapshot()
    })

    afterEach(async () => {
        await rpc.revert(snapshotId)
    })

    it("checkpoint delegator", async () => {
        await bondingManager.checkpointBondingState(delegator.address)
    })

    it("checkpoint transcoder", async () => {
        await bondingManager.checkpointBondingState(transcoder.address)
    })

    it("checkpoint non-participant", async () => {
        await bondingManager.checkpointBondingState(signers[99].address)
    })
})
