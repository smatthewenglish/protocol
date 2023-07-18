// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20SnapshotUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IVotes } from "../../treasury/GovernorCountingOverridable.sol";
import "../../bonding/libraries/SortedArrays.sol";

/**
 * @dev Minimum implementation of an IVotes interface to test the GovernorCountingOverridable extension. It inherits
 * from the default ERC20VotesUpgradeable implementation but overrides the voting power functions to provide power to
 * delegators as well (to be made overridable by the GovernorCountingOverridable extension).
 */
contract VotesMock is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    ERC20VotesUpgradeable,
    IVotes
{
    mapping(address => uint256[]) private _delegateChangingTimes;
    mapping(address => mapping(uint256 => address)) private _delegatedAtTime;

    function initialize() public initializer {
        __ERC20_init("VotesMock", "VTCK");
        __ERC20Burnable_init();
        __Ownable_init();
        __ERC20Votes_init();
    }

    function delegatedAt(address _account, uint256 _timepoint) external view returns (address) {
        uint256[] storage rounds = _delegateChangingTimes[_account];
        if (rounds.length == 0 || _timepoint < rounds[0]) {
            return address(0);
        }

        uint256 prevRound = SortedArrays.findLowerBound(rounds, _timepoint);
        return _delegatedAtTime[_account][prevRound];
    }

    function _delegate(address _delegator, address _to) internal override {
        super._delegate(_delegator, _to);

        uint256 currTime = clock();

        uint256[] storage rounds = _delegateChangingTimes[_delegator];
        SortedArrays.pushSorted(rounds, currTime);
        _delegatedAtTime[_delegator][currTime] = _to;
    }

    /**
     * @dev Simulates the behavior of our actual voting power, where the delegator also has voting power which can
     * override their transcoder's vote. This is not the case in the OpenZeppelin implementation.
     */
    function getPastVotes(address account, uint256 blockNumber)
        public
        view
        override(IVotesUpgradeable, ERC20VotesUpgradeable)
        returns (uint256)
    {
        // Blatant simplification that only works in our tests where we never change participants balance during
        // proposal voting period. We check and return delegators current state instead of tracking historical values.
        if (delegates(account) != account) {
            return balanceOf(account);
        }
        return super.getPastVotes(account, blockNumber);
    }

    /**
     * @dev Same as above. Still don't understand why the OZ implementation for these 2 is incompatible, with getPast*
     * reverting if you query it with the current round.
     */
    function getVotes(address account)
        public
        view
        override(IVotesUpgradeable, ERC20VotesUpgradeable)
        returns (uint256)
    {
        if (delegates(account) != account) {
            return balanceOf(account);
        }
        return super.getVotes(account);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // The following functions are overrides required by Solidity.

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._burn(account, amount);
    }
}
