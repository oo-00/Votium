const fetch = require("node-fetch");
const { request, gql } = require('graphql-request');
const Web3 = require('web3');
const { ethers } = require("ethers");
const web3 = new Web3();

const infura_json = require("./infura.json");
const INFURA_KEY = infura_json.api_key;

/////////////////////////////////////////////////////////////////////////////////////////////
//          EDIT PROVIDER AS NEEDED:                                                      //
                                                                                         //
const mainnetProvider = new ethers.providers.InfuraProvider("mainnet", INFURA_KEY);     //
const fantomProvider = new ethers.providers.JsonRpcProvider("https://rpc.ftm.tools/"); //
                                                                                      //
///////////////////////////////////////////////////////////////////////////////////////

const votiumABI = [{"inputs":[],"stateMutability":"nonpayable","type":"constructor"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address","name":"_token","type":"address"},{"indexed":false,"internalType":"uint256","name":"_amount","type":"uint256"},{"indexed":true,"internalType":"bytes32","name":"_proposal","type":"bytes32"},{"indexed":false,"internalType":"uint256","name":"_choiceIndex","type":"uint256"}],"name":"Bribed","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"bytes32","name":"_proposal","type":"bytes32"}],"name":"Initiated","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address","name":"_member","type":"address"},{"indexed":false,"internalType":"bool","name":"_approval","type":"bool"}],"name":"ModifiedTeam","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"previousOwner","type":"address"},{"indexed":true,"internalType":"address","name":"newOwner","type":"address"}],"name":"OwnershipTransferred","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"internalType":"address","name":"_token","type":"address"},{"indexed":false,"internalType":"address","name":"_distributor","type":"address"}],"name":"UpdatedDistributor","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"uint256","name":"_feeAmount","type":"uint256"}],"name":"UpdatedFee","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"bool","name":"_requireWhitelist","type":"bool"}],"name":"WhitelistRequirement","type":"event"},{"anonymous":false,"inputs":[{"indexed":false,"internalType":"address","name":"_token","type":"address"}],"name":"Whitelisted","type":"event"},{"inputs":[],"name":"DENOMINATOR","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"_hash","type":"bytes32"}],"name":"approveDelegationVote","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"","type":"address"}],"name":"approvedTeam","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"name":"delegationHash","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"_token","type":"address"},{"internalType":"uint256","name":"_amount","type":"uint256"},{"internalType":"bytes32","name":"_proposal","type":"bytes32"},{"internalType":"uint256","name":"_choiceIndex","type":"uint256"}],"name":"depositBribe","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"feeAddress","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"_proposal","type":"bytes32"},{"internalType":"uint256","name":"_deadline","type":"uint256"},{"internalType":"uint256","name":"_maxIndex","type":"uint256"}],"name":"initiateProposal","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"bytes32","name":"_hash","type":"bytes32"},{"internalType":"bytes","name":"_signature","type":"bytes"}],"name":"isWinningSignature","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"_member","type":"address"},{"internalType":"bool","name":"_approval","type":"bool"}],"name":"modifyTeam","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"owner","outputs":[{"internalType":"address","name":"","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"platformFee","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"name":"proposalInfo","outputs":[{"internalType":"uint256","name":"deadline","type":"uint256"},{"internalType":"uint256","name":"maxIndex","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"requireWhitelist","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"bool","name":"_requireWhitelist","type":"bool"}],"name":"setWhitelistRequired","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"","type":"address"}],"name":"tokenInfo","outputs":[{"internalType":"bool","name":"whitelist","type":"bool"},{"internalType":"address","name":"distributor","type":"address"}],"stateMutability":"view","type":"function"},{"inputs":[{"internalType":"address","name":"newOwner","type":"address"}],"name":"transferOwnership","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"_token","type":"address"}],"name":"transferToDistributor","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"_token","type":"address"},{"internalType":"address","name":"_distributor","type":"address"}],"name":"updateDistributor","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"_feeAddress","type":"address"}],"name":"updateFeeAddress","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"uint256","name":"_feeAmount","type":"uint256"}],"name":"updateFeeAmount","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address","name":"_token","type":"address"}],"name":"whitelistToken","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"internalType":"address[]","name":"_tokens","type":"address[]"}],"name":"whitelistTokens","outputs":[],"stateMutability":"nonpayable","type":"function"}];

const mainnetAddress = '0x19BBC3463Dd8d07f55438014b021Fb457EBD4595';
const fantomAddress  = '0xB8834B76ADd8fA60CeC20f7c82F7489AC6CdA5B9';
const space = 'cvx.eth';
const snapshot_endpoint = "https://hub.snapshot.org/graphql";
const SNAPSHOT_SCORE_API = 'https://score.snapshot.org/api/scores';
const tokenOptions = require("./tokens.json");

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', (input) => {
  choice = input;
});

async function getDepositEvents(id) {
  try {
		let depres = [];
		mainnetContract = await new ethers.Contract(
        mainnetAddress,
        votiumABI,
        mainnetProvider
    );
    let filter = await mainnetContract.filters.Bribed(
        null,
        null,
        web3.utils.keccak256(id),
        null
    );
    let mainres = await mainnetContract.queryFilter(filter);
		for(i in mainres) {
			obj = [];
			obj[0] = mainres[i].args[0];
			obj[1] = mainres[i].args[1];
			obj[2] = mainres[i].args[2];
			obj[3] = mainres[i].args[3];
			depres.push(obj);
		}
		fantomContract = await new ethers.Contract(
				fantomAddress,
				votiumABI,
				fantomProvider
		);
		filter = await fantomContract.filters.Bribed(
				null,
				null,
				web3.utils.keccak256(id),
				null
		);
		let ftmres = await fantomContract.queryFilter(filter);
		for(i in ftmres) {
			obj = [];
			obj[0] = ftmres[i].args[0];
			obj[1] = ftmres[i].args[1];
			obj[2] = ftmres[i].args[2];
			obj[3] = ftmres[i].args[3];
			depres.push(obj);
		}
    return depres;
  } catch(e) {
    console.log(e);
  }
}

const metaData = [
  {
    "name": "erc20-balance-of",
    "params": {
      "symbol": "CVX",
      "address": "0xD18140b4B819b895A3dba5442F959fA44994AF50",
      "decimals": 18
    }
  },
  {
    "name": "delegation",
    "params": {
      "symbol": "CVX",
      "strategies": [
        {
          "name": "erc20-balance-of",
          "params": {
            "symbol": "CVX",
            "address": "0xD18140b4B819b895A3dba5442F959fA44994AF50",
            "decimals": 18
          }
        }
      ]
    }
  }
];


const grabProposal = async (hashId) => {
  const proposalQuery = gql`
    query {
        proposal(id:"${hashId}") {
          id
          title
          body
          choices
          start
          end
          snapshot
          state
          author
          created
          plugins
          network
          strategies {
            name
            params
          }
          space {
            id
            name
          }
        }
      }
    `
  var response = await request(snapshot_endpoint, proposalQuery);
  return response.proposal;
}

const getVoters = async (hashId) => {
  const votersQuery = gql`
    query Votes {
        votes (
          first: 1000000000
          where: {
            proposal: "${hashId}"
          }
          orderBy: "created",
          orderDirection: desc
        ) {
          id
          voter
          created
          proposal {
            id
          }
          choice
          space {
            id
          }
        }
      }

    `
  var response = await request(snapshot_endpoint, votersQuery);
 //console.log(response);
 //console.log('Number of votes: ' + response.votes.length);
  return response.votes;
}

const getVoteScores = async (block, voteAddresses, strategy) => {
  const params = {
    space: "cvx.eth",
    network: "1",
    snapshot: Number(block),
    strategies: strategy,
    addresses: voteAddresses
  };
  var init = {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ params })
  };
  var response = await fetch(SNAPSHOT_SCORE_API, init);
  var obj = await response.json();
  var totalAddresses = {};
  var totalScore = 0;
  for (var i in obj.result.scores) {
    for (var x in voteAddresses) {
      if (obj.result.scores[i][voteAddresses[x]] != undefined) {
        totalScore = totalScore + obj.result.scores[i][voteAddresses[x]];
      }
      if (totalAddresses[voteAddresses[x]] == undefined && obj.result.scores[i][voteAddresses[x]] != undefined) {
        totalAddresses[voteAddresses[x]] = obj.result.scores[i][voteAddresses[x]]
      } else {
        if (obj.result.scores[i][voteAddresses[x]] != undefined) {
          totalAddresses[voteAddresses[x]] = totalAddresses[voteAddresses[x]] + obj.result.scores[i][voteAddresses[x]];
        }
      }
    }
  }
  return totalAddresses;
}

async function getProposals(query) {
  try {
    res = await fetch(snapshot_endpoint+"?", {
     "headers": { "content-type": "application/json" },
     "body": query,
      "method": "POST"
    });
    res = await res.text()
    res = JSON.parse(res);
    if(res.data.proposals[0] != null) {
      return res.data.proposals;
    } else {
      return null;
    }
  } catch(e){
      console.log(e)
  }
}

const main = async () => {


  // GET PRICES

  list = '';
  for(i=0;i<tokenOptions.length;i++) {
    list = list+tokenOptions[i].label;
    if(i+1<tokenOptions.length) {
      list = list+",";
    }
  }
  res = await fetch("https://api.coingecko.com/api/v3/simple/price?ids="+list+"&vs_currencies=usd", {
  });
  res = await res.text()
  res = JSON.parse(res);
  if(res.dai != undefined) {
    prices = [];
    for(i=0;i<tokenOptions.length;i++) {
      if(res[tokenOptions[i].label] != undefined) {
        prices[tokenOptions[i].value.toUpperCase()] = res[tokenOptions[i].label].usd;
      }
    }
  }

  // SELECT PROPOSAL

  query = "{\"query\":\"query Proposals { proposals ( first: 1000, skip: 0, where: { space_in: [\\\"cvx.eth\\\"], state: \\\"any\\\" }, orderBy: \\\"created\\\", orderDirection: desc ) { id title body choices start end snapshot state author type space { id name } }}\",\"variables\":null,\"operationName\":\"Proposals\"}";
  proposals = await getProposals(query);
  if(proposals == null) { process.exit(); }
  for(i=0;i<proposals.length;i++) {
    if(proposals[i].choices.length > 15) {
      console.log(i+": "+proposals[i].title);
    }
  }
  console.log("Please enter choice: [0-"+(i-1)+"]");
  choice = null;
  while(choice == null) {
    await sleep(500);
  }

  // GET REWARD INFO

  res = await getDepositEvents(proposals[Number(choice)].id);
  rewards = {};
  for(i in res) {
    address = res[i][0];
    amount = res[i][1].toString();
		for(f in tokenOptions) {
			if(tokenOptions[f]["value"].toUpperCase() == address.toUpperCase()) {
				decimals = tokenOptions[f]["decimals"];
			}
		}
    pool = Number(res[i][3].toString())+1;
    if(rewards[pool] == null || rewards[pool] == undefined) { rewards[pool] = {}; }
    if(rewards[pool][address] == null || rewards[pool][address] == undefined) { rewards[pool][address] = 0; }
    if(rewards[pool].total_value == null || rewards[pool].total_value == undefined) { rewards[pool].total_value = 0; }
    token_amount = Number(amount) / Math.pow(10, decimals);
    rewards[pool][address] += token_amount;
    rewards[pool].total_value += token_amount*prices[address.toUpperCase()];
  }
  for(i in rewards) {
    rewards[i].total_value = Number(Number(Math.round(rewards[i].total_value*100)/100).toFixed(2));
  }

  // DO VOTE TALLYING

  toGrab = proposals[Number(choice)].id;
  var proposal = await grabProposal(toGrab);
  var snapshot_block = proposal.snapshot;
  var voters = await getVoters(toGrab);

  var votersCheck = [];
  for (var i in voters) {
      votersCheck.push(voters[i].voter);
  }

  var voterScores = await getVoteScores(snapshot_block, votersCheck, proposal.strategies);
  poolShot = {};
  for(i=0;i<voters.length;i++) {
    userPower = voterScores[voters[i].voter];
      userWeightDenominator = 0;
      for(n in voters[i].choice) {
        userWeightDenominator += voters[i].choice[n];
      }
      for(n in voters[i].choice) {
        if(poolShot[n.toString()] == null || poolShot[n.toString()] == undefined) { poolShot[n.toString()] = 0; }
        poolShot[n.toString()] += voterScores[voters[i].voter]*(voters[i].choice[n]/userWeightDenominator);
      }
  }

  // Calculate rewards

  // exception for mim-ust limit in round 3
  if(proposal.id == "QmaS9vd1vJKQNBYX4KWQ3nppsTT3QSL3nkz5ZYSwEJk6hZ") {
    proposal.choices[51] = "mim/mim-ust";
    poolShot[52] += poolShot[41];
  }

  // remove pools without rewards
  for(i in poolShot) {
    if(rewards[i] == undefined || rewards[i] == null) {
      delete(poolShot[i])
    }
  }

  // display results
  total_usd = 0;
  total_votes = 0;
  console.log("┌───────────────┬───────────────┬───────────────┬────────────┐\n│      POOL     │    REWARDS    │     VOTES     │   $/VOTE   │\n├───────────────┼───────────────┼───────────────┼────────────┤")
  for(i in rewards) {
		if(poolShot[i] == undefined) { poolShot[i] = 0; }
    price_per = rewards[i].total_value/poolShot[i];
    console.log("│ "+proposal.choices[i-1].padEnd(14, ' ')+"│ $"+rewards[i].total_value.toFixed(2).padStart(12, ' ')+" │ "+poolShot[i].toFixed(2).padStart(12, ' ')+"  │ $"+price_per.toFixed(5).padStart(9, ' ')+" │");
    total_usd += rewards[i].total_value;
    total_votes += poolShot[i];
  }
  console.log("└───────────────┴───────────────┴───────────────┴────────────┘");
  console.log("\nTotal Rewards:       $"+total_usd.toFixed(2));
  console.log("Total Votes:         "+total_votes.toFixed(2));
  console.log("Average $ per vote:  $"+(total_usd/total_votes).toFixed(5));
  if(proposal.end < Math.floor(Date.now()/1000)) {
    console.log("\nPlease note this proposal has already ended. Prices shown reflect the current token prices today, not the prices at the time of the proposal.");
  }
  process.exit();
}

main();
