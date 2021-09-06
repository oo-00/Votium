const fetch = require('node-fetch');
const Web3 = require('web3');
const web3 = new Web3('http://localhost:8545'); // replace with infura if no local node running

vlCVX = "0xD18140b4B819b895A3dba5442F959fA44994AF50"
vlABI = [{"inputs":[{"internalType":"address","name":"_user","type":"address"}],"name":"lockedBalanceOf","outputs":[{"internalType":"uint256","name":"amount","type":"uint256"}],"stateMutability":"view","type":"function"}];


voteProxy = "0xde1E6A7ED0ad3F61D531a8a78E83CcDdbd6E0c49";

lockContract = new web3.eth.Contract(vlABI, vlCVX);

// fetch delegates from snapshot graphql
async function getDelegates() {
  res = await fetch("https://api.thegraph.com/subgraphs/name/snapshot-labs/snapshot", {
   "headers": {
   "content-type": "application/json"
   },
   "body": "{\"query\":\"query { delegations (where: {delegate: \\\""+voteProxy+"\\\"}, first: 1000) { delegator space } }\"}",
   "method": "POST"
  });
  res = await res.text()
  res = JSON.parse(res);
  addressList  = {};
  delegateList = [];
  delegateListUpper = [];
  if(res.data != null) {
    res.data.delegations.forEach(key => {
      if(key.space == "cvx.eth") {
        delegateList.push(key.delegator);
      }
    });
    return delegateList;
  }
  return null;
}

// get on chain total locked balances of delegates
async function getDelegationTotal() {
	res = await getDelegates();
	userLocks = 0;
	for(i=0;i<res.length;i++) {
		individual = await lockContract.methods.lockedBalanceOf(res[i]).call();
		userLocks = Number(userLocks)+Number(web3.utils.fromWei(individual, "ether"));
	}
	console.log(userLocks);
	return userLocks;
}

getDelegationTotal();
