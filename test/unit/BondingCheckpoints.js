import Fixture from "./helpers/Fixture"
import {
    // contractId,
    functionSig
    // functionEncodedABI
} from "../../utils/helpers"
// import {constants} from "../../utils/constants"
// import math from "../helpers/math"
import {assert} from "chai"
import {ethers, web3} from "hardhat"
// const BigNumber = ethers.BigNumber
import chai from "chai"
import {solidity} from "ethereum-waffle"

chai.use(solidity)
// const {expect} = chai
// const {DelegatorStatus, TranscoderStatus} = constants

// TODO: to be moved in a separate util/config (i.e: chai-setup)
chai.use(function(chai) {
    const Assertion = chai.Assertion

    Assertion.addMethod("matchStruct", function(expected) {
        // eslint-disable-next-line no-invalid-this
        const obj = this._obj

        Object.keys(expected).forEach(function(key) {
            if (Array.isArray(obj[key])) {
                new Assertion(obj[key]).to.deep.eq(expected[key])
            } else {
                new Assertion(obj[key]).to.eq(expected[key])
            }
        })
    })
})

describe.only("BondingCheckpoints", () => {
    let fixture
    let bondingManager
    let bondingCheckpoints

    const NUM_ACTIVE_TRANSCODERS = 2
    const UNBONDING_PERIOD = 2

    const PERC_DIVISOR = 1000000
    const PERC_MULTIPLIER = PERC_DIVISOR / 100

    // const ZERO_ADDRESS = ethers.constants.AddressZero

    let signers
    before(async () => {
        signers = await ethers.getSigners()
        fixture = new Fixture(web3)
        await fixture.deploy()

        const llFac = await ethers.getContractFactory("SortedDoublyLL")
        const ll = await llFac.deploy()
        const bondingManagerFac = await ethers.getContractFactory(
            "BondingManager",
            {
                libraries: {
                    SortedDoublyLL: ll.address
                }
            }
        )

        bondingManager = await fixture.deployAndRegister(
            bondingManagerFac,
            "BondingManager",
            fixture.controller.address
        )

        await bondingManager.setUnbondingPeriod(UNBONDING_PERIOD)
        await bondingManager.setNumActiveTranscoders(NUM_ACTIVE_TRANSCODERS)

        const bondingCheckpointsFac = await ethers.getContractFactory(
            "BondingCheckpoints"
        )

        bondingCheckpoints = await fixture.deployAndRegister(
            bondingCheckpointsFac,
            "BondingCheckpoints",
            fixture.controller.address
        )
    })

    beforeEach(async () => {
        await fixture.setUp()
    })

    afterEach(async () => {
        await fixture.tearDown()
    })

    describe("pendingStake", () => {
        let transcoder
        let delegator
        let currentRound

        beforeEach(async () => {
            transcoder = signers[0]
            delegator = signers[1]
            currentRound = 100

            await fixture.roundsManager.setMockBool(
                functionSig("currentRoundInitialized()"),
                true
            )
            await fixture.roundsManager.setMockBool(
                functionSig("currentRoundLocked()"),
                false
            )

            // Round R-2
            await fixture.roundsManager.setMockUint256(
                functionSig("currentRound()"),
                currentRound - 2
            )

            await bondingCheckpoints
                .connect(transcoder)
                .initDelegatorCheckpoint(transcoder.address)
            await bondingManager
                .connect(transcoder)
                .bond(1000, transcoder.address)
            await bondingManager
                .connect(transcoder)
                .transcoder(50 * PERC_MULTIPLIER, 25 * PERC_MULTIPLIER)

            // Round R-1
            await fixture.roundsManager.setMockUint256(
                functionSig("currentRound()"),
                currentRound - 1
            )
            await bondingCheckpoints
                .connect(delegator)
                .initDelegatorCheckpoint(delegator.address)
            await bondingManager
                .connect(delegator)
                .bond(1000, transcoder.address)

            // Round R
            await fixture.roundsManager.setMockUint256(
                functionSig("currentRound()"),
                currentRound
            )

            await fixture.minter.setMockUint256(
                functionSig("createReward(uint256,uint256)"),
                1000
            )
            await bondingManager.connect(transcoder).reward()

            // Round R+1
            await fixture.roundsManager.setMockUint256(
                functionSig("currentRound()"),
                currentRound + 1
            )

            await bondingManager.connect(transcoder).reward()

            // Round R+2
            await fixture.roundsManager.setMockUint256(
                functionSig("currentRound()"),
                currentRound + 2
            )
        })

        it("should return partial rewards for any rounds since bonding", async () => {
            const pendingRewards0 = 250
            const pendingRewards1 = Math.floor(
                (500 * ((1250 * PERC_DIVISOR) / 3000)) / PERC_DIVISOR
            )

            const stakeAt = round =>
                bondingCheckpoints
                    .getStakeAt(delegator.address, round)
                    .then(n => n.toString())

            assert.equal(await stakeAt(1), 0)
            assert.equal(await stakeAt(currentRound - 10), 0)
            assert.equal(await stakeAt(currentRound - 1), 0)
            assert.equal(await stakeAt(currentRound), 1000)
            assert.equal(
                await stakeAt(currentRound + 1),
                1000 + pendingRewards0
            )
            assert.equal(
                await stakeAt(currentRound + 2),
                1000 + pendingRewards0 + pendingRewards1
            )
        })

        it("should return partial rewards for all transcoder stake", async () => {
            const stakeAt = round =>
                bondingCheckpoints
                    .getStakeAt(transcoder.address, round)
                    .then(n => n.toString())

            assert.equal(await stakeAt(1), 0)
            assert.equal(await stakeAt(currentRound - 10), 0)
            // transcoder bonding is only valid on the following round
            assert.equal(await stakeAt(currentRound - 2), 0)
            assert.equal(await stakeAt(currentRound - 1), 1000)
            assert.equal(await stakeAt(currentRound), 2000)
            assert.equal(await stakeAt(currentRound + 1), 3000)
            assert.equal(await stakeAt(currentRound + 2), 4000)
        })
    })
})
