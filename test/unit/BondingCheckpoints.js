import Fixture from "./helpers/Fixture"
import {functionSig} from "../../utils/helpers"
import {assert} from "chai"
import {ethers, web3} from "hardhat"
import chai from "chai"
import {solidity} from "ethereum-waffle"
import {constants} from "ethers"

chai.use(solidity)
const {expect} = chai

describe.only("BondingCheckpoints", () => {
    let fixture
    let bondingCheckpoints

    const NUM_ACTIVE_TRANSCODERS = 2
    const UNBONDING_PERIOD = 2

    const PERC_DIVISOR = 1000000
    const PERC_MULTIPLIER = PERC_DIVISOR / 100

    let signers
    before(async () => {
        signers = await ethers.getSigners()
        fixture = new Fixture(web3)
        await fixture.deploy()

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

    // TODO: Move this to BondingManager tests
    describe("initBondingCheckpoint", () => {
        let bondingManager

        let transcoder
        let delegator
        let currentRound

        const setRound = async round => {
            await fixture.roundsManager.setMockUint256(
                functionSig("currentRound()"),
                round
            )
            await fixture.roundsManager.execute(
                bondingManager.address,
                functionSig("setCurrentRoundTotalActiveStake()")
            )
        }

        beforeEach(async () => {
            transcoder = signers[0]
            delegator = signers[1]
            currentRound = 100

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

            // Unregister BondingCheckpoints from controller so it doesn't get state updates. This is the trick we use
            // to simulate not having the checkpoints deployed yet to see the migration of the data once it is
            await fixture.register("BondingCheckpoints", constants.AddressZero)

            await fixture.roundsManager.setMockBool(
                functionSig("currentRoundInitialized()"),
                true
            )
            await fixture.roundsManager.setMockBool(
                functionSig("currentRoundLocked()"),
                false
            )

            // Round R-2
            await setRound(currentRound - 2)

            await bondingManager
                .connect(transcoder)
                .bond(1000, transcoder.address)
            await bondingManager
                .connect(transcoder)
                .transcoder(50 * PERC_MULTIPLIER, 25 * PERC_MULTIPLIER)

            // Round R-1
            await setRound(currentRound - 1)

            await bondingManager
                .connect(delegator)
                .bond(1000, transcoder.address)

            // Round R
            await setRound(currentRound)

            await fixture.minter.setMockUint256(
                functionSig("createReward(uint256,uint256)"),
                1000
            )

            // Now let's register back the BondingCheckpoints contract as if it was deployed in the current round
            await fixture.register(
                "BondingCheckpoints",
                bondingCheckpoints.address
            )
        })

        const stakeAt = (account, round) =>
            bondingCheckpoints
                .getAccountStakeAt(account.address, round)
                .then(n => n.toString())

        it("should revert if bonding checkpoint is not registered", async () => {
            await fixture.register("BondingCheckpoints", constants.AddressZero)

            await expect(
                bondingManager.initBondingCheckpoint(transcoder.address)
            ).to.be.revertedWith("bonding checkpoints not available")
        })

        it("should revert if account already initialized", async () => {
            await bondingManager.initBondingCheckpoint(transcoder.address)

            await expect(
                bondingManager.initBondingCheckpoint(transcoder.address)
            ).to.be.revertedWith("account already checkpointed")
        })

        it("should allow querying on the round after it is called", async () => {
            await expect(stakeAt(transcoder, currentRound)).to.be.revertedWith(
                "findLowerBound: empty array"
            )

            await bondingManager.initBondingCheckpoint(transcoder.address)

            // Round R+1
            await setRound(currentRound + 1)

            // checkpoint only valid for next round
            await expect(stakeAt(transcoder, currentRound)).to.be.revertedWith(
                "findLowerBound: all values in array are higher than searched value"
            )

            assert.equal(await stakeAt(transcoder, currentRound + 1), 2000)
        })

        it("should have no problems if state gets updated again in round", async () => {
            await bondingManager.initBondingCheckpoint(transcoder.address)

            await bondingManager.connect(transcoder).reward()

            // Round R+1
            await setRound(currentRound + 1)

            assert.equal(await stakeAt(transcoder, currentRound + 1), 3000)
        })

        it("should still create checkpoints even if never inited", async () => {
            await bondingManager.connect(transcoder).reward()

            // Round R+1
            await setRound(currentRound + 1)

            assert.equal(await stakeAt(transcoder, currentRound + 1), 3000)

            await expect(
                stakeAt(delegator, currentRound + 1)
            ).to.be.revertedWith("findLowerBound: empty array")

            await bondingManager
                .connect(delegator)
                .bond(1000, transcoder.address)

            // Round R+2
            await setRound(currentRound + 2)

            assert.equal(await stakeAt(delegator, currentRound + 2), 2250) // 1000 + 500 * 1000 / 2000 + 1000
            assert.equal(await stakeAt(transcoder, currentRound + 2), 4000)
        })
    })

    describe("checkpointBonding", () => {
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

            const setRound = async round => {
                await fixture.roundsManager.setMockUint256(
                    functionSig("currentRound()"),
                    round
                )
                await fixture.roundsManager.execute(
                    fixture.bondingManager.address,
                    functionSig("setCurrentRoundTotalActiveStake()")
                )
            }

            // Round R-2
            await setRound(currentRound)
        })

        const checkpointBonding = (account, startRound) => {
            const functionData =
                bondingCheckpoints.interface.encodeFunctionData(
                    "checkpointBonding",
                    [
                        account.address,
                        startRound, // start round
                        1000, // bonded amount
                        transcoder.address, // delegate address
                        account === transcoder ? 1000 : 0, // delegated amount
                        startRound - 1, // last claim round
                        account === transcoder ? currentRound - 1 : 0 // last reward round
                    ]
                )
            return fixture.bondingManager.execute(
                bondingCheckpoints.address,
                functionData
            )
        }

        it("should revert if caller is not bonding manager", async () => {
            await expect(
                bondingCheckpoints.checkpointBonding(
                    delegator.address,
                    0,
                    0,
                    constants.AddressZero,
                    0,
                    0,
                    0
                )
            ).to.be.revertedWith("caller must be BondingManager")
        })

        it("should revert if round is in the future", async () => {
            await expect(checkpointBonding(delegator, 102)).to.be.revertedWith(
                "future lookup"
            )
        })
    })
})
