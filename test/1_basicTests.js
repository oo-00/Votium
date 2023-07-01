// const { BN, constants, expectEvent, expectRevert, time } = require('openzeppelin-test-helpers');
const { BN, time } = require('openzeppelin-test-helpers');
var jsonfile = require('jsonfile');
const { assert } = require('chai');
const { web3 } = require('openzeppelin-test-helpers/src/setup');

const verbose = true;

const Votium = artifacts.require("Votium");

const ERC20 = artifacts.require("IERC20");

const addAccount = async (address) => {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "evm_addAccount",
        params: [address, "passphrase"],
        id: new Date().getTime(),
      },
      (err, result) => {
        if (err) {
          return reject(err);
        }
        return resolve(result);
      }
    );
  });
};

const unlockAccount = async (address) => {
  await addAccount(address);
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "personal_unlockAccount",
        params: [address, "passphrase",15000],
        id: new Date().getTime(),
      },
      (err, result) => {
        if (err) {
          return reject(err);
        }
        return resolve(result);
      }
    );
  });
};

const send = payload => {
  if (!payload.jsonrpc) payload.jsonrpc = '2.0';
  if (!payload.id) payload.id = new Date().getTime();

  return new Promise((resolve, reject) => {
    web3.currentProvider.send(payload, (error, result) => {
      if (error) return reject(error);

      return resolve(result);
    });
  });
};

/**
 *  Mines a single block in Ganache (evm_mine is non-standard)
 */
const mineBlock = () => send({ method: 'evm_mine' });
const mineMultiBlock = (blockCnt) => send({ method: 'evm_mine', options:{blocks:blockCnt } });
/**
 *  Gets the time of the last block.
 */
const currentTime = async () => {
  const { timestamp } = await web3.eth.getBlock('latest');
  return timestamp;
};

/**
 *  Increases the time in the EVM.
 *  @param seconds Number of seconds to increase the time by
 */
const fastForward = async seconds => {
  // It's handy to be able to be able to pass big numbers in as we can just
  // query them from the contract, then send them back. If not changed to
  // a number, this causes much larger fast forwards than expected without error.
  if (BN.isBN(seconds)) seconds = seconds.toNumber();

  // And same with strings.
  if (typeof seconds === 'string') seconds = parseFloat(seconds);

  await send({
    method: 'evm_increaseTime',
    params: [seconds],
  });

  // await mineBlock();
  await mineMultiBlock(1000);
};


const getChainContracts = () => {
  let NETWORK = config.network;//process.env.NETWORK;
  console.log("network: " +NETWORK);
  var contracts = {};

  if(NETWORK == "debugZkevm" || NETWORK == "mainnetZkevm"){
    contracts = contractList.zkevm;
  }else if(NETWORK == "debug" || NETWORK == "mainnet"){
    contracts = contractList.mainnet;
  }

  return contracts;
}

const advanceTime = async (secondsElaspse) => {
  await time.increase(secondsElaspse);
  await time.advanceBlock();
  console.log("\n  >>>>  advance time " +(secondsElaspse/86400) +" days  >>>>\n");
}
const day = 86400;

async function tryCatch(promise, expected) {
  try {
    await promise;
    return false;
  }
  catch (e) {
    return true;
  }
}

function verboseLog(msg) {
  if (verbose) {
    console.log(msg);
  }
}


const addressZero = "0x0000000000000000000000000000000000000000"

var userA;
var userB;
var userC;
var userD;
var userE;
var userF;
var userG;
var userH;
var userI;
var userJ;

var userX = "0xAdE9e51C9E23d64E538A7A38656B78aB6Bcc349e";
var userY = "0xC8076F60cbDd2EE93D54FCc0ced88095A72f4a2f";
var userZ = "0xAAc0aa431c237C2C0B5f041c8e59B3f1a43aC78F";
var cvxHolder = "0x15A5F10cC2611bB18b18322E34eB473235EFCa39";
var weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
var userNames = {};
userNames[userA] = "A";
userNames[userB] = "B";
userNames[userC] = "C";
userNames[userD] = "D";
userNames[userX] = "X";
userNames[userY] = "Y";
userNames[userZ] = "Z";

var deployer = "0xB4421830226F9C5Ff32060B96a3b9F8D2E0E132D";
var feeAddress = "0x29e3b0E8dF4Ee3f71a62C34847c34E139fC0b297";
var distributor = "0x378Ba9B73309bE80BF4C2c027aAD799766a7ED5A"
var multisig = "0xe39b8617D571CEe5e75e1EC6B2bb40DdC8CF6Fa3";

var maxRounds = 7;

var votium;

var round;
var fee;
var expectedIncentivesLength = {};
var expectedGaugesLength = {};
var inRoundGauges = {};
var owner;
var approved1;
var approved2;
var notApproved;
var _feeAddress;
var _distributor;

var CVXaddress = "0x4e3fbd56cd56c3e72c1403e103b45db9da5b9d2b";
var CVX;
var tokenAllowed;

var depositMinusFee = 0;
var vdepositMinusFee = new BN(0);
var gaugeArr;

var tokenBal = {};
var tokenVBal = {};

async function testDepositSchema(schema, token, amount, round_s, gauge_s, max) {
  var effectedRounds = [];
  switch(schema) {
    case "depositIncentive": // depositIncentive
      assert(gauge_s.length == 1, "gauge_s must be length 1 for depositIncentive");
      /*
        address _token,
        uint256 _amount,
        uint256 _round,
        address _gauge,
        uint256 _maxPerVote
      */
      verboseLog("test depositIncentive with rounds in acceptable range, maxPerVote: " +max);
      amountMinusFee = amount.sub(amount.mul(new BN(fee)).div(new BN(10000)));
      incentiveAmount = amountMinusFee; // no division for this schema
      for(k in round_s) {
        verboseLog(" depositIncentive round: " +(round_s[k]));
        await votium.depositIncentive(token, amount.toString(), round_s[k], gauge_s[0], max, {from:cvxHolder});
        if(expectedIncentivesLength[gauge_s[0]] == undefined) { expectedIncentivesLength[gauge_s[0]] = {}; }
        if(expectedIncentivesLength[gauge_s[0]][round_s[k]] == undefined) { expectedIncentivesLength[gauge_s[0]][round_s[k]] = 0; }
        expectedIncentivesLength[gauge_s[0]][round_s[k]]++;
        if(expectedGaugesLength[round_s[k]] == undefined) { expectedGaugesLength[round_s[k]] = 0; }
        if(inRoundGauges[round_s[k]] == undefined) { inRoundGauges[round_s[k]] = {}; }
        if(inRoundGauges[round_s[k]][gauge_s[0]] == undefined) {
          inRoundGauges[round_s[k]][gauge_s[0]] = 1;
          expectedGaugesLength[round_s[k]]++;
        }
        if(tokenBal[token] == undefined) { tokenBal[token] = new BN(0); }
        if(tokenVBal[token] == undefined) { tokenVBal[token] = new BN(0); }
        tokenBal[token] = tokenBal[token].add(amountMinusFee);
        tokenVBal[token] = tokenVBal[token].add(amountMinusFee); // no division for this schema
        effectedRounds.push(round_s[k]);
      }

      break;
    case "depositSplitRounds": // depositSplitRounds
      assert(gauge_s.length == 1, "gauge_s must be length 1 for depositSplitRounds");
      assert(round_s.length == 1, "round_s must be length 1 for depositSplitRounds");
      /*
        address _token,
        uint256 _amount,
        uint256 _numRounds,
        address _gauge,
        uint256 _maxPerVote
      */
      verboseLog("test depositSplitRounds with "+round_s[0]+" rounds, maxPerVote: " +max);
      await votium.depositSplitRounds(token, amount.toString(), round_s[0], gauge_s[0], max, {from:cvxHolder});
      if(tokenBal[token] == undefined) { tokenBal[token] = new BN(0); }
      if(tokenVBal[token] == undefined) { tokenVBal[token] = new BN(0); }
      amountMinusFee = amount.sub(amount.mul(new BN(fee)).div(new BN(10000)));
      incentiveAmount = amountMinusFee.div(new BN(round_s[0])); 
      tokenBal[token] = tokenBal[token].add(amountMinusFee);
      tokenVBal[token] = tokenVBal[token].add(incentiveAmount.mul(new BN(round_s[0]))); 
      for(i=round;i<round_s[0]+round;i++) {
        if(expectedIncentivesLength[gauge_s[0]] == undefined) { expectedIncentivesLength[gauge_s[0]] = {}; }
        if(expectedIncentivesLength[gauge_s[0]][i] == undefined) { expectedIncentivesLength[gauge_s[0]][i] = 0; }
        expectedIncentivesLength[gauge_s[0]][i]++;
        if(expectedGaugesLength[i] == undefined) { expectedGaugesLength[i] = 0; }
        if(inRoundGauges[i] == undefined) { inRoundGauges[i] = {}; }
        if(inRoundGauges[i][gauge_s[0]] == undefined) {
          inRoundGauges[i][gauge_s[0]] = 1;
          expectedGaugesLength[i]++;
        }
        effectedRounds.push(i);
      }
      break;
    case "depositSplitGauges": // depositSplitGauges
      assert(gauge_s.length > 1, "gauge_s must be length >1 for depositSplitGauges");
      assert(round_s.length == 1, "round_s must be length 1 for depositSplitGauges");
      /*
        address _token,
        uint256 _amount,
        uint256 _round,
        address[] calldata _gauges,
        uint256 _maxPerVote
      */
      verboseLog("test depositSplitGauges in round "+round_s[0]+" with "+gauge_s.length+" gauges, maxPerVote: " +max);
      await votium.depositSplitGauges(token, amount.toString(), round_s[0], gauge_s, max, {from:cvxHolder});
      if(tokenBal[token] == undefined) { tokenBal[token] = new BN(0); }
      if(tokenVBal[token] == undefined) { tokenVBal[token] = new BN(0); }
      amountMinusFee = amount.sub(amount.mul(new BN(fee)).div(new BN(10000)));
      incentiveAmount = amountMinusFee.div(new BN(gauge_s.length)); 
      tokenBal[token] = tokenBal[token].add(amountMinusFee);
      tokenVBal[token] = tokenVBal[token].add(incentiveAmount.mul(new BN(gauge_s.length))); 
      effectedRounds.push(round_s[0]);
      for(i=0;i<gauge_s.length;i++) {
        if(expectedIncentivesLength[gauge_s[i]] == undefined) { expectedIncentivesLength[gauge_s[i]] = {}; }
        if(expectedIncentivesLength[gauge_s[i]][round_s[0]] == undefined) { expectedIncentivesLength[gauge_s[i]][round_s[0]] = 0; }
        expectedIncentivesLength[gauge_s[i]][round_s[0]]++;
        if(expectedGaugesLength[round_s[0]] == undefined) { expectedGaugesLength[round_s[0]] = 0; }
        if(inRoundGauges[round_s[0]] == undefined) { inRoundGauges[round_s[0]] = {}; }
        if(inRoundGauges[round_s[0]][gauge_s[i]] == undefined) {
          inRoundGauges[round_s[0]][gauge_s[i]] = 1;
          expectedGaugesLength[round_s[0]]++;
        }
      }
      break;
    case "depositSplitGaugesRounds": // depositSplitGaugesRounds
      assert(gauge_s.length > 1, "gauge_s must be length >1 for depositSplitGaugesRounds");
      assert(round_s.length == 1, "round_s must be length 1 for depositSplitGaugesRounds");
      /*
        address _token,
        uint256 _amount,
        uint256 _numRounds,
        address[] calldata _gauges,
        uint256 _maxPerVote
      */
      verboseLog("test depositSplitGaugesRounds for "+round_s[0]+" rounds with "+gauge_s.length+" gauges, maxPerVote: " +max);
      await votium.depositSplitGaugesRounds(token, amount.toString(), round_s[0], gauge_s, max, {from:cvxHolder});
      if(tokenBal[token] == undefined) { tokenBal[token] = new BN(0); }
      if(tokenVBal[token] == undefined) { tokenVBal[token] = new BN(0); }
      amountMinusFee = amount.sub(amount.mul(new BN(fee)).div(new BN(10000)));
      incentiveAmount = amountMinusFee.div(new BN(gauge_s.length)).div(new BN(round_s[0])); 
      tokenBal[token] = tokenBal[token].add(amountMinusFee);
      tokenVBal[token] = tokenVBal[token].add(incentiveAmount.mul(new BN(gauge_s.length)).mul(new BN(round_s[0]))); 
      for(n=round;n<round_s[0]+round;n++) {
        effectedRounds.push(n);
        for(i=0;i<gauge_s.length;i++) {
          if(expectedIncentivesLength[gauge_s[i]] == undefined) { expectedIncentivesLength[gauge_s[i]] = {}; }
          if(expectedIncentivesLength[gauge_s[i]][n] == undefined) { expectedIncentivesLength[gauge_s[i]][n] = 0; }
          expectedIncentivesLength[gauge_s[i]][n]++;
          if(expectedGaugesLength[n] == undefined) { expectedGaugesLength[n] = 0; }
          if(inRoundGauges[n] == undefined) { inRoundGauges[n] = {}; }
          if(inRoundGauges[n][gauge_s[i]] == undefined) {
            inRoundGauges[n][gauge_s[i]] = 1;
            expectedGaugesLength[n]++;
          }
        }
      }
      break;
    case "depositUnevenSplitGauges": // depositUnevenSplitGauges
      /*
        address _token,
        uint256 _round,
        address[] calldata _gauges,
        uint256[] calldata _amounts,
        uint256 _maxPerVote
      */
      break;
    default:
      assert(false, "invalid schema");
      return;
  }

  var balance = await CVX.balanceOf(votium.address);
  verboseLog("   balance: " +balance);
  assert(balance == tokenBal[token].toString(), "balance should be "+tokenBal[token].toString());
  var virtualBalance = await votium.virtualBalance(CVXaddress);
  verboseLog("   virtualBalance: " +virtualBalance);
  assert(virtualBalance == tokenVBal[token].toString(), "virtualBalance should be "+tokenVBal[token].toString());

  for(var i=0; i<effectedRounds.length; i++) {
    var gaugesLength = await votium.gaugesLength(effectedRounds[i]);
    verboseLog("     gaugesLength: " +gaugesLength);
    assert(gaugesLength == expectedGaugesLength[effectedRounds[i]], "round "+effectedRounds[i]+" gaugesLength should be "+expectedGaugesLength[effectedRounds[i]]);

    for(var n=0; n<gauge_s.length; n++) {
      var gauge = await votium.roundGauges(effectedRounds[i], expectedGaugesLength[effectedRounds[i]]-gauge_s.length+n);
      verboseLog("     gauge: " +gauge);
      assert(gauge == gauge_s[n], "round "+(effectedRounds[i])+" gauge "+(expectedGaugesLength[effectedRounds[i]]-gauge_s.length+n)+" should be "+gauge_s[n]);
  
      var incentivesLength = await votium.incentivesLength(effectedRounds[i], gauge);
      verboseLog("     incentivesLength: " +incentivesLength);

      assert(incentivesLength == expectedIncentivesLength[gauge_s[n]][effectedRounds[i]], "round "+(effectedRounds[i])+" gauge "+gauge_s[n]+" incentivesLength should be "+expectedIncentivesLength[gauge_s[n]][effectedRounds[i]]);
  
      var incentive = await votium.incentives(effectedRounds[i], gauge, Number(incentivesLength)-1);
      verboseLog("     incentive: ");
      verboseLog("       token: "+incentive.token);
      verboseLog("       amount: "+incentive.amount.toString());
      verboseLog("       maxPerVote: "+incentive.maxPerVote.toString());
      verboseLog("       distributed: "+incentive.distributed.toString());
      verboseLog("       recycled: "+incentive.recycled.toString());
      verboseLog("       depositor: "+incentive.depositor);

      verboseLog("      amount should be "+incentiveAmount.toString());
      assert(incentive.amount.toString() == incentiveAmount.toString(), "incentive amount should be "+incentiveAmount.toString());
    }
  }
}

contract("Deploy System and test", async accounts => {
    it("should deploy system", async () => {

      userA = accounts[0];
      userB = accounts[1];
      userC = accounts[2];
      userD = accounts[3];
      userE = accounts[4];
      userF = accounts[5];
      userG = accounts[6];
      userH = accounts[7];
      userI = accounts[8];
      userJ = accounts[9];


      expectedIncentivesLength[userZ] = {};
      expectedIncentivesLength[userA] = {};
    
      verboseLog("deployer: " +deployer);
      await unlockAccount(deployer);
      await unlockAccount(userX);
      await unlockAccount(cvxHolder);
      await unlockAccount(weth);

      // send 5 eth from weth to deployer and to cvxHolder to cover gas costs (weth chosen as a gaurantee of having eth on mainnet)
      await web3.eth.sendTransaction({from:weth, to:deployer, value:web3.utils.toWei("5", "ether")});
      await web3.eth.sendTransaction({from:weth, to:cvxHolder, value:web3.utils.toWei("5", "ether")});

      //constructor(address _approved, address _approved2, address _feeAddress, address _distributor)
      votium = await Votium.new(userY, userX, feeAddress, distributor, {from:deployer});
      verboseLog("votium: " +votium.address);
      assert(votium.address != addressZero, "votium address is zero");

      owner = await votium.owner();
      approved1 = await votium.approvedTeam(userX);
      approved2 = await votium.approvedTeam(userY);
      notApproved = await votium.approvedTeam(userZ);
      _feeAddress = await votium.feeAddress();
      _distributor = await votium.distributor();
      round = await votium.activeRound();
      fee = await votium.platformFee();
      tokenAllowed = await votium.tokenAllowed(CVXaddress);


      round = Number(round)
      fee = Number(fee)

      verboseLog("owner: " +owner);
      verboseLog("approved1: " +approved1);
      verboseLog("approved2: " +approved2);
      verboseLog("notApproved: " +notApproved);
      verboseLog("feeAddress: " +_feeAddress);
      verboseLog("distributor: " +_distributor);
      verboseLog("\nround: " +round);
      verboseLog("fee: " +fee);
    });

    it("should have correct initial values", async () => {
      assert(owner == multisig, "owner should be multisig");
      assert(approved1 == true, "userX should be approved");
      assert(approved2 == true, "userY should be approved");
      assert(notApproved == false, "userZ should not be approved");
      assert(_feeAddress == feeAddress, "feeAddress is wrong");
      assert(_distributor == distributor, "distributor is wrong");
      assert(tokenAllowed == false, "token allowed after deployment");
    });

    // chainContracts.system.votium = votium.address;
    // jsonfile.writeFileSync("./contracts.json", contractList, { spaces: 4 });


    //!!!!!!!!!!!!!!!!!!!!!! ALLOW LIST TESTS !!!!!!!!!!!!!!!!!!

    it("cvxHolder approve spending", async () => {
      CVX = await ERC20.at(CVXaddress);
      // approve CVX spending from cvxHolder to votium
      verboseLog("approve CVX spending from cvxHolder to votium")
      await CVX.approve(votium.address, web3.utils.toWei("1000000000", "ether"), {from:cvxHolder});
      var allowance = await CVX.allowance(cvxHolder, votium.address);
      verboseLog(" allowance: " +allowance);
      assert(allowance == web3.utils.toWei("1000000000", "ether"), "allowance should be 1 billion");
    });
    
    it("should not allow deposits before allowlisting", async () => {
      // try to depositIncentive before allowlisting
      verboseLog("test depositIncentive before allowlisting")
      fail = await tryCatch(votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositIncentive before allowlisting");
      verboseLog(" depositIncentive failed as expected");
      verboseLog("test depositSplitRounds before allowlisting")
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 2, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds before allowlisting");
      verboseLog(" depositSplitRounds failed as expected");
      verboseLog("test depositSplitGauges before allowlisting")
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("10000", "ether"), round, [userZ,weth], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges before allowlisting");
      verboseLog(" depositSplitGauges failed as expected");
      verboseLog("test depositSplitGaugesRounds before allowlisting")
      fail = await tryCatch(votium.depositSplitGaugesRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 2, [userZ,weth], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGaugesRounds before allowlisting");
      verboseLog(" depositSplitGaugesRounds failed as expected");
      verboseLog("test depositUnevenSplitGauges before allowlisting");
      fail = await tryCatch(votium.depositUnevenSplitGauges(CVXaddress, round, [userA,userB], [web3.utils.toWei("3000", "ether"),web3.utils.toWei("4000", "ether")], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositUnevenSplitGauges before allowlisting");
      verboseLog(" depositUnevenSplitGauges failed as expected");
    });
    // try allowToken CVX from not approved address
    it("should not allow `allowToken` from not approved address", async () => {
      verboseLog("test allowToken true from not approved address")
      fail = await tryCatch(votium.allowToken(CVXaddress, true, {from:userZ}));
      assert(fail, "should fail to allowToken from not approved address");
      verboseLog(" allowToken failed as expected")
    });

    // allowlist CVX from approved address
    it("should allow `allowToken` from approved address", async () => {
      verboseLog("test allowToken true from approved address")
      await votium.allowToken(CVXaddress, true, {from:userX});
      tokenAllowed = await votium.tokenAllowed(CVXaddress);
      verboseLog(" tokenAllowed: " +tokenAllowed);
      assert(tokenAllowed == true, "CVX should be allowed after allowToken");
    });

    //!!!!!!!!!!!!!!!!!!!!!! DEPOSITINCENTIVE TESTS !!!!!!!!!!!!!!!!!!

    
    it("should not allow depositIncentive outside of round range", async () => {
      verboseLog("test depositIncentive with a round too far into the future")
      fail = await tryCatch(votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round+maxRounds, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositIncentive with a round too far into the future");
      verboseLog(" depositIncentive failed as expected");
      verboseLog("test depositIncentive with a round in the past")
      fail = await tryCatch(votium.depositIncentive(CVXaddress, web3.utils.toWei("10000", "ether"), round-1, userZ, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositIncentive with a round in the past");
      verboseLog(" depositIncentive failed as expected");
    });

    it("should allow depositIncentive with rounds in acceptable range, maxPerVote: 0", async () => {
      await testDepositSchema("depositIncentive", CVXaddress, new BN(web3.utils.toWei("100", "ether")), [round+0,round+6], [userZ], 0);
    });
    it("should allow depositIncentive with rounds in acceptable range, maxPerVote: .001", async () => {
      await testDepositSchema("depositIncentive", CVXaddress, new BN(web3.utils.toWei("200", "ether")), [round+0,round+6], [userZ], web3.utils.toWei(".001", "ether"));
    });
    
    //!!!!!!!!!!!!!!!!!!!!!! DEPOSITSPLITROUNDS TESTS !!!!!!!!!!!!!!!!!!

    it("should not allow depositSplitRounds outside of round range", async () => {
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), maxRounds+1, userA, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds with "+(maxRounds+1)+" rounds");
      verboseLog(" depositSplitRounds failed as expected");
      verboseLog("test depositSplitRounds with 0 rounds");
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 0, userA, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds with 0 rounds");
      verboseLog(" depositSplitRounds failed as expected");
      verboseLog("test depositSplitRounds with 1 round");
      fail = await tryCatch(votium.depositSplitRounds(CVXaddress, web3.utils.toWei("10000", "ether"), 1, userA, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitRounds with 1 round");
      verboseLog(" depositSplitRounds failed as expected");
    });

    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: 0", async () => {
      await testDepositSchema("depositSplitRounds", CVXaddress, new BN(web3.utils.toWei("1000", "ether")), [2], [userA], 0);
    });
    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: .0015", async () => {
      await testDepositSchema("depositSplitRounds", CVXaddress, new BN(web3.utils.toWei("1000", "ether")), [2], [userA], web3.utils.toWei(".0015", "ether"));
    });

    //!!!!!!!!!!!!!!!!!!!!!! DEPOSITSPLITGAUGES TESTS !!!!!!!!!!!!!!!!!!

    it("should not allow depositSplitGauges outside of gauge/round range", async () => {
      gaugeArr = [userC,userD,userE,userF,userG,userH,userI];

      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round+maxRounds, gaugeArr, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with for round "+(round+maxRounds));
      verboseLog(" depositSplitGauges failed as expected");
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round-1, gaugeArr, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with for round "+(round-1));
      verboseLog(" depositSplitGauges failed as expected");
      verboseLog("test depositSplitGauges with 0 or 1 gauges");
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round+maxRounds, [], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with 0 gauges");
      fail = await tryCatch(votium.depositSplitGauges(CVXaddress, web3.utils.toWei("100", "ether"), round+maxRounds, [userA], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGauges with 1 gauge");
      verboseLog(" depositSplitGauges failed as expected");
    });

    it("should allow depositSplitGauges with rounds and gauges in acceptable range, maxPerVote: 0", async () => {
      await testDepositSchema("depositSplitGauges", CVXaddress, new BN(web3.utils.toWei("500", "ether")), [round], [userA, userB], 0);
    });
    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: .001233333333333333", async () => {
      await testDepositSchema("depositSplitGauges", CVXaddress, new BN(web3.utils.toWei("500", "ether")), [round], [userA, userB], "1233333333333333");
    });

    it("should not allow depositSplitGaugesRounds outside of gauge/round range", async () => {
      gaugeArr = [userC,userD,userE,userF,userG,userH,userI];

      fail = await tryCatch(votium.depositSplitGaugesRounds(CVXaddress, web3.utils.toWei("100", "ether"), 1, gaugeArr, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGaugesRounds with with less than 2 rounds ");
      verboseLog(" depositSplitGaugesRounds failed as expected");
      fail = await tryCatch(votium.depositSplitGaugesRounds(CVXaddress, web3.utils.toWei("100", "ether"), maxRounds+1, gaugeArr, 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGaugesRounds with for "+(maxRounds+1)+" rounds");
      verboseLog(" depositSplitGaugesRounds failed as expected");
      verboseLog("test depositSplitGaugesRounds with 0 or 1 gauges");
      fail = await tryCatch(votium.depositSplitGaugesRounds(CVXaddress, web3.utils.toWei("100", "ether"), 2, [], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGaugesRounds with 0 gauges");
      fail = await tryCatch(votium.depositSplitGaugesRounds(CVXaddress, web3.utils.toWei("100", "ether"), 2, [userA], 0, {from:cvxHolder}));
      assert(fail, "should fail to depositSplitGaugesRounds with 1 gauge");
      verboseLog(" depositSplitGaugesRounds failed as expected");
    });

    it("should allow depositSplitGaugesRounds with rounds and gauges in acceptable range, maxPerVote: 0", async () => {
      await testDepositSchema("depositSplitGaugesRounds", CVXaddress, new BN(web3.utils.toWei("500", "ether")), [2], [userA, userB], 0);
    });
    it("should allow depositSplitRounds with rounds in acceptable range, maxPerVote: .000333333333333333", async () => {
      await testDepositSchema("depositSplitGaugesRounds", CVXaddress, new BN(web3.utils.toWei("500", "ether")), [2], [userA, userB], "333333333333333");
    });

    return;
});


