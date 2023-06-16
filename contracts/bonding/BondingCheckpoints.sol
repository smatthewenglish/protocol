// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/utils/Arrays.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./libraries/EarningsPool.sol";
import "./libraries/EarningsPoolLIP36.sol";

import "../ManagerProxyTarget.sol";
import "../IController.sol";
import "../rounds/IRoundsManager.sol";
import "./BondingManager.sol";

contract BondingCheckpoints is ManagerProxyTarget, IBondingCheckpoints {
    uint256 public constant MAX_ROUNDS_WITHOUT_CHECKPOINT = 100;

    constructor(address _controller) Manager(_controller) {}

    struct BondingCheckpoint {
        uint256 bondedAmount; // The amount of bonded tokens to another delegate as per the lastClaimRound
        address delegateAddress; // The address delegated to
        uint256 delegatedAmount; // The amount of tokens delegated to the account (only set for transcoders)
        uint256 lastClaimRound; // The last round during which the delegator claimed its earnings. Pegs the value of bondedAmount for rewards calculation
        uint256 lastRewardRound; // The last round during which the transcoder called rewards. This is useful to find the reward pool when calculating historical rewards. Notice that this actually comes from the Transcoder struct in bonding manager, not Delegator.
    }

    struct BondingCheckpointsByRound {
        uint256[] startRounds;
        mapping(uint256 => BondingCheckpoint) data;
    }

    mapping(address => BondingCheckpointsByRound) private bondingCheckpoints;

    uint256[] totalStakeCheckpointRounds;
    mapping(uint256 => uint256) private totalActiveStakeCheckpoints;

    // IERC5805 interface implementation

    /**
     * @notice Clock is set to match the current round, which is the checkpointing
     *  method implemented here.
     */
    function clock() public view returns (uint48) {
        return SafeCast.toUint48(roundsManager().currentRound());
    }

    /**
     * @notice Machine-readable description of the clock as specified in EIP-6372.
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure returns (string memory) {
        // TODO: Figure out the right value for this
        return "mode=livepeer_round&from=default";
    }

    /**
     * @notice Returns the current amount of votes that `account` has.
     */
    function getVotes(address _account) external view returns (uint256) {
        return getAccountActiveStakeAt(_account, clock());
    }

    /**
     * @notice Returns the amount of votes that `account` had at a specific moment in the past. If the `clock()` is
     * configured to use block numbers, this will return the value at the end of the corresponding block.
     */
    function getPastVotes(address _account, uint256 _timepoint) external view returns (uint256) {
        return getAccountActiveStakeAt(_account, _timepoint);
    }

    /**
     * @notice Returns the total supply of votes available at a specific round in the past.
     * @dev This value is the sum of all *active* stake, which is not necessarily the sum of all voting power.
     * Bonded stake that is not part of the top 100 active transcoder set is still given voting power, but is not
     * considered here.
     */
    function getPastTotalSupply(uint256 _timepoint) external view returns (uint256) {
        return getTotalActiveStakeAt(_timepoint);
    }

    /**
     * @notice Returns the delegate that _account has chosen. This means the delegated transcoder address in case of
     * delegators, and the account own address for transcoders (self-delegated).
     */
    function delegates(address _account) external view returns (address) {
        return delegatedAt(_account, clock());
    }

    /**
     * @notice Returns the delegate that _account had chosen in a specific round in the past. See `delegates()` above
     * for more details.
     * @dev This is an addition to the IERC5805 interface to support our custom vote counting logic that allows
     * delegators to override their transcoders votes. See {GovernorVotesBondingCheckpoints-_handleVoteOverrides}.
     */
    function delegatedAt(address _account, uint256 _round) public view returns (address) {
        BondingCheckpoint storage bond = getBondingCheckpointAt(_account, _round);
        return bond.delegateAddress;
    }

    /**
     * @notice Delegation through BondingCheckpoints is not supported.
     */
    function delegate(address) external pure {
        revert("use BondingManager to update vote delegation through bonding");
    }

    /**
     * @notice Delegation through BondingCheckpoints is not supported.
     */
    function delegateBySig(
        address,
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external pure {
        revert("use BondingManager to update vote delegation through bonding");
    }

    // BondingManager checkpointing hooks

    /**
     * @notice Called by the BondingManager when the bonding state of an account changes.
     * @dev Since we checkpoint "delegator" and "transcoder" states, this is called both for the delegator and for the
     * transcoder when any change is made to the bonds, including when rewards are calculated or claimed.
     * @param _account The account whose bonding state changed
     * @param _startRound The round from which the bonding state will be active. This is normally the next round.
     * @param _bondedAmount From {BondingManager-Delegator-bondedAmount}
     * @param _delegateAddress From {BondingManager-Delegator-delegateAddress}
     * @param _delegatedAmount From {BondingManager-Transcoder-delegatedAmount}
     * @param _lastClaimRound From {BondingManager-Delegator-lastClaimRound}
     * @param _lastRewardRound From {BondingManager-Transcoder-lastRewardRound}
     */
    function checkpointBonding(
        address _account,
        uint256 _startRound,
        uint256 _bondedAmount,
        address _delegateAddress,
        uint256 _delegatedAmount,
        uint256 _lastClaimRound,
        uint256 _lastRewardRound
    ) public virtual onlyBondingManager {
        require(_startRound <= clock() + 1, "can only checkpoint delegator up to the next round");
        require(_lastClaimRound < _startRound, "claim round must always be lower than start round");

        BondingCheckpointsByRound storage checkpoints = bondingCheckpoints[_account];

        checkpoints.data[_startRound] = BondingCheckpoint(
            _bondedAmount,
            _delegateAddress,
            _delegatedAmount,
            _lastClaimRound,
            _lastRewardRound
        );

        // now store the startRound itself in the startRounds array to allow us
        // to find it and lookup in the above mapping
        pushSorted(checkpoints.startRounds, _startRound);
    }

    /**
     * @notice Returns whether an account already has any checkpoint.
     * @dev This is used in BondingManager logic to initialize the checkpointing of existing accounts. It is meant to be
     * called once we deploy the checkpointing logic for the first time, so we have a starting checkpoint from all
     * accounts in the system.
     */
    function hasCheckpoint(address _account) external virtual returns (bool) {
        return bondingCheckpoints[_account].startRounds.length > 0;
    }

    /**
     * @notice Called by the BondingManager when the total active stake changes.
     * @dev This is called only from the {BondingManager-setCurrentRoundTotalActiveStake} function to set the total
     * active stake in the current round.
     * @param _totalStake From {BondingManager-currentRoundTotalActiveStake}
     * @param _round The round for which the total active stake is valid. This is normally the current round.
     */
    function checkpointTotalActiveStake(uint256 _totalStake, uint256 _round) public virtual onlyBondingManager {
        require(_round <= clock(), "can only checkpoint total active stake in the current round");

        totalActiveStakeCheckpoints[_round] = _totalStake;

        pushSorted(totalStakeCheckpointRounds, _round);
    }

    // Internal logic

    /**
     * @dev Gets the checkpointed total active stake at a given round.
     * @param _round The round for which we want to get the total active stake.
     */
    function getTotalActiveStakeAt(uint256 _round) internal view virtual returns (uint256) {
        require(_round <= clock(), "getTotalActiveStakeAt: future lookup");

        // most of the time we will have the checkpoint from exactly the round we want
        uint256 activeStake = totalActiveStakeCheckpoints[_round];
        if (activeStake > 0) {
            return activeStake;
        }

        uint256 round = ensureLowerLookup(totalStakeCheckpointRounds, _round);
        return totalActiveStakeCheckpoints[round];
    }

    /**
     * @dev Gets the active stake of an account at a given round. In case of delegators it is the amount they are
       delegating to a transcoder, while for transcoders this is all the stake that has been delegated to them
       (including self-delegated).
     * @param _account The account whose bonding state we want to get.
     * @param _round The round for which we want to get the bonding state. Normally a proposal's vote start round.
     * @return The active stake of the account at the given round including any accrued rewards.
     */
    function getAccountActiveStakeAt(address _account, uint256 _round) internal view returns (uint256) {
        require(_round <= clock(), "getStakeAt: future lookup");

        BondingCheckpoint storage bond = getBondingCheckpointAt(_account, _round);
        bool isTranscoder = bond.delegateAddress == _account;

        if (bond.bondedAmount == 0) {
            return 0;
        } else if (isTranscoder) {
            // Address is a registered transcoder so we use its delegated amount. This includes self and delegated stake
            // as well as any accrued rewards, even unclaimed ones
            return bond.delegatedAmount;
        } else {
            // Address is NOT a registered transcoder so we calculate its cumulative stake for the voting power
            return delegatorCumulativeStakeAt(bond, _round);
        }
    }

    /**
     * @dev Gets the checkpointed bonding state of an account at a round. This works by looking for the last checkpoint
     * at or before the given round and using the checkpoint of that round. If there hasn't been checkpoints since then
     * it means that the state hasn't changed.
     * @param _account The account whose bonding state we want to get.
     * @param _round The round for which we want to get the bonding state.
     * @return The {BondingCheckpoint} pointer to the checkpoints storage.
     */
    function getBondingCheckpointAt(address _account, uint256 _round)
        internal
        view
        returns (BondingCheckpoint storage)
    {
        BondingCheckpointsByRound storage checkpoints = bondingCheckpoints[_account];
        uint256 startRound = ensureLowerLookup(checkpoints.startRounds, _round);
        return checkpoints.data[startRound];
    }

    /**
     * @dev Gets the cumulative stake of a delegator at any given round. Differently from the bonding manager
     * implementation, we can calculate the stake at any round through the use of the checkpointed state. It works by
     * re-using the bonding manager logic while changing only the way that we find the earning pool for the end round.
     * @param bond The {BondingCheckpoint} of the delegator at the given round.
     * @param _round The round for which we want to get the cumulative stake.
     * @return The cumulative stake of the delegator at the given round.
     */
    function delegatorCumulativeStakeAt(BondingCheckpoint storage bond, uint256 _round)
        internal
        view
        returns (uint256)
    {
        EarningsPool.Data memory startPool = getTranscoderEarningPoolForRound(
            bond.delegateAddress,
            bond.lastClaimRound
        );
        require(startPool.cumulativeRewardFactor > 0, "missing earning pool from delegator's last claim round");

        (uint256 rewardRound, EarningsPool.Data memory endPool) = getTranscoderLastRewardsEarningPool(
            bond.delegateAddress,
            _round
        );

        // Only allow reward factor to be zero if transcoder had never called reward()
        require(
            endPool.cumulativeRewardFactor > 0 || rewardRound == 0,
            "missing transcoder earning pool on reported last reward round"
        );

        if (rewardRound < bond.lastClaimRound) {
            // If the transcoder hasn't called reward() since the last time the delegator claimed earnings, there wil be
            // no rewards to add to the delegator's stake so we just return the originally bonded amount.
            return bond.bondedAmount;
        }

        (uint256 stakeWithRewards, ) = bondingManager().delegatorCumulativeStakeAndFees(
            startPool,
            endPool,
            bond.bondedAmount,
            0
        );
        return stakeWithRewards;
    }

    /**
     * @notice Returns the last initialized earning pool for a transcoder at a given round.
     * @dev Transcoders are just delegators with a self-delegation, so we find their last checkpoint before or at the
     * provided _round and use its lastRewardRound value to grab the calculated earning pool. The only case where this
     * returns a zero earning pool is if the transcoder had never called reward() before _round.
     * @param _transcoder Address of the transcoder to look for
     * @param _round Past round at which we want the valid earning pool from
     * @return rewardRound Round in which the returned earning pool was calculated.
     * @return pool EarningsPool.Data struct with the last initialized earning pool.
     */
    function getTranscoderLastRewardsEarningPool(address _transcoder, uint256 _round)
        internal
        view
        returns (uint256 rewardRound, EarningsPool.Data memory pool)
    {
        // Most of the time we will already have the checkpoint from exactly the round we want
        BondingCheckpoint storage bond = bondingCheckpoints[_transcoder].data[_round];

        if (bond.lastRewardRound == 0) {
            bond = getBondingCheckpointAt(_transcoder, _round);
        }

        rewardRound = bond.lastRewardRound;
        pool = getTranscoderEarningPoolForRound(_transcoder, rewardRound);
    }

    /**
     * @dev Proxy for {BondingManager-getTranscoderEarningsPoolForRound} that returns an EarningsPool.Data struct.
     */
    function getTranscoderEarningPoolForRound(address _transcoder, uint256 _round)
        internal
        view
        returns (EarningsPool.Data memory pool)
    {
        (
            pool.totalStake,
            pool.transcoderRewardCut,
            pool.transcoderFeeShare,
            pool.cumulativeRewardFactor,
            pool.cumulativeFeeFactor
        ) = bondingManager().getTranscoderEarningsPoolForRound(_transcoder, _round);
    }

    // array checkpointing logic
    // TODO: move to a library?

    function ensureLowerLookup(uint256[] storage array, uint256 val) internal view returns (uint256) {
        (uint256 lower, bool found) = lowerLookup(array, val);
        require(found, "ensureLowerLookup: no lower or equal value found in array");
        return lower;
    }

    function lowerLookup(uint256[] storage array, uint256 val) internal view returns (uint256, bool) {
        uint256 len = array.length;
        if (len == 0) {
            return (0, false);
        }

        uint256 lastElm = array[len - 1];
        if (lastElm <= val) {
            return (lastElm, true);
        }

        uint256 upperIdx = Arrays.findUpperBound(array, val);

        // we already checked the last element above so the upper must be inside the array
        require(upperIdx < len, "lowerLookup: invalid index returned by findUpperBound");

        uint256 upperElm = array[upperIdx];
        // the value we were searching is in the array
        if (upperElm == val) {
            return (val, true);
        }

        // the first value in the array is already higher than the value we wanted
        if (upperIdx == 0) {
            return (0, false);
        }

        // the upperElm is the first element higher than the value we want, so return the previous element
        return (array[upperIdx - 1], true);
    }

    function pushSorted(uint256[] storage array, uint256 val) internal {
        if (array.length == 0) {
            array.push(val);
        } else {
            uint256 last = array[array.length - 1];

            // values must be pushed in order
            require(val >= last, "pushSorted: decreasing values");

            // don't push duplicate values
            if (val != last) {
                array.push(val);
            }
        }
    }

    // Manager/Controller helpers

    /**
     * @dev Modified to ensure the sender is BondingManager
     */
    modifier onlyBondingManager() {
        _onlyBondingManager();
        _;
    }

    /**
     * @dev Return BondingManager interface
     */
    function bondingManager() internal view returns (BondingManager) {
        return BondingManager(controller.getContract(keccak256("BondingManager")));
    }

    /**
     * @dev Return IRoundsManager interface
     */
    function roundsManager() public view returns (IRoundsManager) {
        return IRoundsManager(controller.getContract(keccak256("RoundsManager")));
    }

    /**
     * @dev Ensure the sender is BondingManager
     */
    function _onlyBondingManager() internal view {
        require(msg.sender == address(bondingManager()), "caller must be BondingManager");
    }
}
