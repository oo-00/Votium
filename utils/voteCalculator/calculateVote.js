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

const Tpool = '0x752eBeb79963cf0732E9c0fec72a49FD1DEfAEAC';
const PUSDpool = '0x8EE017541375F6Bcd802ba119bdDC94dad6911A1';
const Tabi = [{"name":"TokenExchange","inputs":[{"name":"buyer","type":"address","indexed":true},{"name":"sold_id","type":"uint256","indexed":false},{"name":"tokens_sold","type":"uint256","indexed":false},{"name":"bought_id","type":"uint256","indexed":false},{"name":"tokens_bought","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"AddLiquidity","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amounts","type":"uint256[2]","indexed":false},{"name":"fee","type":"uint256","indexed":false},{"name":"token_supply","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RemoveLiquidity","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amounts","type":"uint256[2]","indexed":false},{"name":"token_supply","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RemoveLiquidityOne","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amount","type":"uint256","indexed":false},{"name":"coin_index","type":"uint256","indexed":false},{"name":"coin_amount","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"CommitNewAdmin","inputs":[{"name":"deadline","type":"uint256","indexed":true},{"name":"admin","type":"address","indexed":true}],"anonymous":false,"type":"event"},{"name":"NewAdmin","inputs":[{"name":"admin","type":"address","indexed":true}],"anonymous":false,"type":"event"},{"name":"CommitNewParameters","inputs":[{"name":"deadline","type":"uint256","indexed":true},{"name":"admin_fee","type":"uint256","indexed":false},{"name":"mid_fee","type":"uint256","indexed":false},{"name":"out_fee","type":"uint256","indexed":false},{"name":"fee_gamma","type":"uint256","indexed":false},{"name":"allowed_extra_profit","type":"uint256","indexed":false},{"name":"adjustment_step","type":"uint256","indexed":false},{"name":"ma_half_time","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"NewParameters","inputs":[{"name":"admin_fee","type":"uint256","indexed":false},{"name":"mid_fee","type":"uint256","indexed":false},{"name":"out_fee","type":"uint256","indexed":false},{"name":"fee_gamma","type":"uint256","indexed":false},{"name":"allowed_extra_profit","type":"uint256","indexed":false},{"name":"adjustment_step","type":"uint256","indexed":false},{"name":"ma_half_time","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RampAgamma","inputs":[{"name":"initial_A","type":"uint256","indexed":false},{"name":"future_A","type":"uint256","indexed":false},{"name":"initial_gamma","type":"uint256","indexed":false},{"name":"future_gamma","type":"uint256","indexed":false},{"name":"initial_time","type":"uint256","indexed":false},{"name":"future_time","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"StopRampA","inputs":[{"name":"current_A","type":"uint256","indexed":false},{"name":"current_gamma","type":"uint256","indexed":false},{"name":"time","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"ClaimAdminFee","inputs":[{"name":"admin","type":"address","indexed":true},{"name":"tokens","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"stateMutability":"nonpayable","type":"constructor","inputs":[{"name":"owner","type":"address"},{"name":"admin_fee_receiver","type":"address"},{"name":"A","type":"uint256"},{"name":"gamma","type":"uint256"},{"name":"mid_fee","type":"uint256"},{"name":"out_fee","type":"uint256"},{"name":"allowed_extra_profit","type":"uint256"},{"name":"fee_gamma","type":"uint256"},{"name":"adjustment_step","type":"uint256"},{"name":"admin_fee","type":"uint256"},{"name":"ma_half_time","type":"uint256"},{"name":"initial_price","type":"uint256"},{"name":"_token","type":"address"},{"name":"_coins","type":"address[2]"}],"outputs":[]},{"stateMutability":"payable","type":"fallback"},{"stateMutability":"view","type":"function","name":"token","inputs":[],"outputs":[{"name":"","type":"address"}]},{"stateMutability":"view","type":"function","name":"coins","inputs":[{"name":"i","type":"uint256"}],"outputs":[{"name":"","type":"address"}]},{"stateMutability":"view","type":"function","name":"A","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"gamma","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"get_virtual_price","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"price_oracle","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"exchange","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"},{"name":"min_dy","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"exchange","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"},{"name":"min_dy","type":"uint256"},{"name":"use_eth","type":"bool"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"exchange","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"},{"name":"min_dy","type":"uint256"},{"name":"use_eth","type":"bool"},{"name":"receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"exchange_underlying","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"},{"name":"min_dy","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"exchange_underlying","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"},{"name":"min_dy","type":"uint256"},{"name":"receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"exchange_extended","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"},{"name":"min_dy","type":"uint256"},{"name":"use_eth","type":"bool"},{"name":"sender","type":"address"},{"name":"receiver","type":"address"},{"name":"cb","type":"bytes"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"get_dy","inputs":[{"name":"i","type":"uint256"},{"name":"j","type":"uint256"},{"name":"dx","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"add_liquidity","inputs":[{"name":"amounts","type":"uint256[2]"},{"name":"min_mint_amount","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"add_liquidity","inputs":[{"name":"amounts","type":"uint256[2]"},{"name":"min_mint_amount","type":"uint256"},{"name":"use_eth","type":"bool"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"payable","type":"function","name":"add_liquidity","inputs":[{"name":"amounts","type":"uint256[2]"},{"name":"min_mint_amount","type":"uint256"},{"name":"use_eth","type":"bool"},{"name":"receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity","inputs":[{"name":"_amount","type":"uint256"},{"name":"min_amounts","type":"uint256[2]"}],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity","inputs":[{"name":"_amount","type":"uint256"},{"name":"min_amounts","type":"uint256[2]"},{"name":"use_eth","type":"bool"}],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity","inputs":[{"name":"_amount","type":"uint256"},{"name":"min_amounts","type":"uint256[2]"},{"name":"use_eth","type":"bool"},{"name":"receiver","type":"address"}],"outputs":[]},{"stateMutability":"view","type":"function","name":"calc_token_amount","inputs":[{"name":"amounts","type":"uint256[2]"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"calc_withdraw_one_coin","inputs":[{"name":"token_amount","type":"uint256"},{"name":"i","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_one_coin","inputs":[{"name":"token_amount","type":"uint256"},{"name":"i","type":"uint256"},{"name":"min_amount","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_one_coin","inputs":[{"name":"token_amount","type":"uint256"},{"name":"i","type":"uint256"},{"name":"min_amount","type":"uint256"},{"name":"use_eth","type":"bool"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_one_coin","inputs":[{"name":"token_amount","type":"uint256"},{"name":"i","type":"uint256"},{"name":"min_amount","type":"uint256"},{"name":"use_eth","type":"bool"},{"name":"receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"claim_admin_fees","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"ramp_A_gamma","inputs":[{"name":"future_A","type":"uint256"},{"name":"future_gamma","type":"uint256"},{"name":"future_time","type":"uint256"}],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"stop_ramp_A_gamma","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"commit_new_parameters","inputs":[{"name":"_new_mid_fee","type":"uint256"},{"name":"_new_out_fee","type":"uint256"},{"name":"_new_admin_fee","type":"uint256"},{"name":"_new_fee_gamma","type":"uint256"},{"name":"_new_allowed_extra_profit","type":"uint256"},{"name":"_new_adjustment_step","type":"uint256"},{"name":"_new_ma_half_time","type":"uint256"}],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"apply_new_parameters","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"revert_new_parameters","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"commit_transfer_ownership","inputs":[{"name":"_owner","type":"address"}],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"apply_transfer_ownership","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"revert_transfer_ownership","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"kill_me","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"unkill_me","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"set_admin_fee_receiver","inputs":[{"name":"_admin_fee_receiver","type":"address"}],"outputs":[]},{"stateMutability":"view","type":"function","name":"lp_price","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"price_scale","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"last_prices","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"last_prices_timestamp","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"initial_A_gamma","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_A_gamma","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"initial_A_gamma_time","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_A_gamma_time","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"allowed_extra_profit","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_allowed_extra_profit","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"fee_gamma","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_fee_gamma","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"adjustment_step","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_adjustment_step","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"ma_half_time","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_ma_half_time","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"mid_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"out_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"admin_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_mid_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_out_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"future_admin_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"balances","inputs":[{"name":"arg0","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"D","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"owner","inputs":[],"outputs":[{"name":"","type":"address"}]},{"stateMutability":"view","type":"function","name":"future_owner","inputs":[],"outputs":[{"name":"","type":"address"}]},{"stateMutability":"view","type":"function","name":"xcp_profit","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"xcp_profit_a","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"virtual_price","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"is_killed","inputs":[],"outputs":[{"name":"","type":"bool"}]},{"stateMutability":"view","type":"function","name":"kill_deadline","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"transfer_ownership_deadline","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"admin_actions_deadline","inputs":[],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"admin_fee_receiver","inputs":[],"outputs":[{"name":"","type":"address"}]}]
const PUSDabi = [{"name":"Transfer","inputs":[{"name":"sender","type":"address","indexed":true},{"name":"receiver","type":"address","indexed":true},{"name":"value","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"Approval","inputs":[{"name":"owner","type":"address","indexed":true},{"name":"spender","type":"address","indexed":true},{"name":"value","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"TokenExchange","inputs":[{"name":"buyer","type":"address","indexed":true},{"name":"sold_id","type":"int128","indexed":false},{"name":"tokens_sold","type":"uint256","indexed":false},{"name":"bought_id","type":"int128","indexed":false},{"name":"tokens_bought","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"TokenExchangeUnderlying","inputs":[{"name":"buyer","type":"address","indexed":true},{"name":"sold_id","type":"int128","indexed":false},{"name":"tokens_sold","type":"uint256","indexed":false},{"name":"bought_id","type":"int128","indexed":false},{"name":"tokens_bought","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"AddLiquidity","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amounts","type":"uint256[2]","indexed":false},{"name":"fees","type":"uint256[2]","indexed":false},{"name":"invariant","type":"uint256","indexed":false},{"name":"token_supply","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RemoveLiquidity","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amounts","type":"uint256[2]","indexed":false},{"name":"fees","type":"uint256[2]","indexed":false},{"name":"token_supply","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RemoveLiquidityOne","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amount","type":"uint256","indexed":false},{"name":"coin_amount","type":"uint256","indexed":false},{"name":"token_supply","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RemoveLiquidityImbalance","inputs":[{"name":"provider","type":"address","indexed":true},{"name":"token_amounts","type":"uint256[2]","indexed":false},{"name":"fees","type":"uint256[2]","indexed":false},{"name":"invariant","type":"uint256","indexed":false},{"name":"token_supply","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"RampA","inputs":[{"name":"old_A","type":"uint256","indexed":false},{"name":"new_A","type":"uint256","indexed":false},{"name":"initial_time","type":"uint256","indexed":false},{"name":"future_time","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"name":"StopRampA","inputs":[{"name":"A","type":"uint256","indexed":false},{"name":"t","type":"uint256","indexed":false}],"anonymous":false,"type":"event"},{"stateMutability":"nonpayable","type":"constructor","inputs":[],"outputs":[]},{"stateMutability":"nonpayable","type":"function","name":"initialize","inputs":[{"name":"_name","type":"string"},{"name":"_symbol","type":"string"},{"name":"_coin","type":"address"},{"name":"_rate_multiplier","type":"uint256"},{"name":"_A","type":"uint256"},{"name":"_fee","type":"uint256"}],"outputs":[],"gas":450772},{"stateMutability":"view","type":"function","name":"decimals","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":318},{"stateMutability":"nonpayable","type":"function","name":"transfer","inputs":[{"name":"_to","type":"address"},{"name":"_value","type":"uint256"}],"outputs":[{"name":"","type":"bool"}],"gas":77977},{"stateMutability":"nonpayable","type":"function","name":"transferFrom","inputs":[{"name":"_from","type":"address"},{"name":"_to","type":"address"},{"name":"_value","type":"uint256"}],"outputs":[{"name":"","type":"bool"}],"gas":115912},{"stateMutability":"nonpayable","type":"function","name":"approve","inputs":[{"name":"_spender","type":"address"},{"name":"_value","type":"uint256"}],"outputs":[{"name":"","type":"bool"}],"gas":37851},{"stateMutability":"view","type":"function","name":"admin_fee","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":438},{"stateMutability":"view","type":"function","name":"A","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":10704},{"stateMutability":"view","type":"function","name":"A_precise","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":10666},{"stateMutability":"view","type":"function","name":"get_virtual_price","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":1023280},{"stateMutability":"view","type":"function","name":"calc_token_amount","inputs":[{"name":"_amounts","type":"uint256[2]"},{"name":"_is_deposit","type":"bool"}],"outputs":[{"name":"","type":"uint256"}],"gas":4029742},{"stateMutability":"nonpayable","type":"function","name":"add_liquidity","inputs":[{"name":"_amounts","type":"uint256[2]"},{"name":"_min_mint_amount","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"add_liquidity","inputs":[{"name":"_amounts","type":"uint256[2]"},{"name":"_min_mint_amount","type":"uint256"},{"name":"_receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"get_dy","inputs":[{"name":"i","type":"int128"},{"name":"j","type":"int128"},{"name":"dx","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}],"gas":2466478},{"stateMutability":"view","type":"function","name":"get_dy_underlying","inputs":[{"name":"i","type":"int128"},{"name":"j","type":"int128"},{"name":"dx","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}],"gas":2475029},{"stateMutability":"nonpayable","type":"function","name":"exchange","inputs":[{"name":"i","type":"int128"},{"name":"j","type":"int128"},{"name":"_dx","type":"uint256"},{"name":"_min_dy","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"exchange","inputs":[{"name":"i","type":"int128"},{"name":"j","type":"int128"},{"name":"_dx","type":"uint256"},{"name":"_min_dy","type":"uint256"},{"name":"_receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"exchange_underlying","inputs":[{"name":"i","type":"int128"},{"name":"j","type":"int128"},{"name":"_dx","type":"uint256"},{"name":"_min_dy","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"exchange_underlying","inputs":[{"name":"i","type":"int128"},{"name":"j","type":"int128"},{"name":"_dx","type":"uint256"},{"name":"_min_dy","type":"uint256"},{"name":"_receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity","inputs":[{"name":"_burn_amount","type":"uint256"},{"name":"_min_amounts","type":"uint256[2]"}],"outputs":[{"name":"","type":"uint256[2]"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity","inputs":[{"name":"_burn_amount","type":"uint256"},{"name":"_min_amounts","type":"uint256[2]"},{"name":"_receiver","type":"address"}],"outputs":[{"name":"","type":"uint256[2]"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_imbalance","inputs":[{"name":"_amounts","type":"uint256[2]"},{"name":"_max_burn_amount","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_imbalance","inputs":[{"name":"_amounts","type":"uint256[2]"},{"name":"_max_burn_amount","type":"uint256"},{"name":"_receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"view","type":"function","name":"calc_withdraw_one_coin","inputs":[{"name":"_burn_amount","type":"uint256"},{"name":"i","type":"int128"}],"outputs":[{"name":"","type":"uint256"}],"gas":1130},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_one_coin","inputs":[{"name":"_burn_amount","type":"uint256"},{"name":"i","type":"int128"},{"name":"_min_received","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"remove_liquidity_one_coin","inputs":[{"name":"_burn_amount","type":"uint256"},{"name":"i","type":"int128"},{"name":"_min_received","type":"uint256"},{"name":"_receiver","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},{"stateMutability":"nonpayable","type":"function","name":"ramp_A","inputs":[{"name":"_future_A","type":"uint256"},{"name":"_future_time","type":"uint256"}],"outputs":[],"gas":162101},{"stateMutability":"nonpayable","type":"function","name":"stop_ramp_A","inputs":[],"outputs":[],"gas":157565},{"stateMutability":"view","type":"function","name":"admin_balances","inputs":[{"name":"i","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}],"gas":7770},{"stateMutability":"nonpayable","type":"function","name":"withdraw_admin_fees","inputs":[],"outputs":[],"gas":40657},{"stateMutability":"view","type":"function","name":"coins","inputs":[{"name":"arg0","type":"uint256"}],"outputs":[{"name":"","type":"address"}],"gas":3123},{"stateMutability":"view","type":"function","name":"balances","inputs":[{"name":"arg0","type":"uint256"}],"outputs":[{"name":"","type":"uint256"}],"gas":3153},{"stateMutability":"view","type":"function","name":"fee","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":3138},{"stateMutability":"view","type":"function","name":"initial_A","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":3168},{"stateMutability":"view","type":"function","name":"future_A","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":3198},{"stateMutability":"view","type":"function","name":"initial_A_time","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":3228},{"stateMutability":"view","type":"function","name":"future_A_time","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":3258},{"stateMutability":"view","type":"function","name":"name","inputs":[],"outputs":[{"name":"","type":"string"}],"gas":13518},{"stateMutability":"view","type":"function","name":"symbol","inputs":[],"outputs":[{"name":"","type":"string"}],"gas":11271},{"stateMutability":"view","type":"function","name":"balanceOf","inputs":[{"name":"arg0","type":"address"}],"outputs":[{"name":"","type":"uint256"}],"gas":3563},{"stateMutability":"view","type":"function","name":"allowance","inputs":[{"name":"arg0","type":"address"},{"name":"arg1","type":"address"}],"outputs":[{"name":"","type":"uint256"}],"gas":3808},{"stateMutability":"view","type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"gas":3408}]


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
		if(tokenOptions[i].label != "stablecoin-pusd") {
			list = list+tokenOptions[i].label;
			if(i+1<tokenOptions.length) {
				list = list+",";
			}
		}
  }
  res = await fetch("https://api.coingecko.com/api/v3/simple/price?ids="+list+"&vs_currencies=usd", {
  });
  res = await res.text()
  res = JSON.parse(res);
	tContract = await new ethers.Contract(Tpool,Tabi,mainnetProvider);
	pusdContract = await new ethers.Contract(PUSDpool,PUSDabi,mainnetProvider);
  if(res.dai != undefined) {
    prices = [];
    for(i=0;i<tokenOptions.length;i++) {
			if(tokenOptions[i].label == "threshold-network-token") {
				prices[tokenOptions[i].value.toUpperCase()] = await tContract.price_oracle();
				prices[tokenOptions[i].value.toUpperCase()] = ethers.utils.formatEther(prices[tokenOptions[i].value.toUpperCase()])*prices['0XC02AAA39B223FE8D0A0E5C4F27EAD9083C756CC2'];
			}	else if(tokenOptions[i].label == "stablecoin-pusd") {
				olp = await pusdContract.calc_withdraw_one_coin("1000000000000000000","0",{from:"0x0000000000000000000000000000000000000000", gasLimit:"999999999999"});
				olp = (1/Number(ethers.utils.formatEther(olp)));
				olp = ethers.utils.parseUnits(olp.toString(), 18);
				olp = await pusdContract.calc_withdraw_one_coin(olp,"1",{from:"0x0000000000000000000000000000000000000000", gasLimit:"999999999999"});
				p3crv = ethers.utils.formatEther(olp)*prices['0X6C3F90F043A72FA612CBAC8115EE7E52BDE6E490'];
				prices[tokenOptions[i].value.toUpperCase()] = p3crv;
			}	else if(res[tokenOptions[i].label] != undefined) {
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

	poolShot = {};
	var checked = {};
  var voterScores = await getVoteScores(snapshot_block, votersCheck, proposal.strategies);
  for(i=0;i<voters.length;i++) {
		if(voterScores[voters[i].voter] != undefined) {
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
  }
	if(votersCheck.length > 0) {
		console.log(votersCheck.length+" address failed to load. rechecking");
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
	console.log("┌──────────────────────┬───────────────┬───────────────┬────────────┐\n│         POOL         │    REWARDS    │     VOTES     │   $/VOTE   │\n├──────────────────────┼───────────────┼───────────────┼────────────┤")
  for(i in rewards) {
		if(poolShot[i] == undefined) { poolShot[i] = 0; }
    price_per = rewards[i].total_value/poolShot[i];
    console.log("│ "+proposal.choices[i-1].padEnd(21, ' ')+"│ $"+rewards[i].total_value.toFixed(2).padStart(12, ' ')+" │ "+poolShot[i].toFixed(2).padStart(12, ' ')+"  │ $"+price_per.toFixed(5).padStart(9, ' ')+" │");
    total_usd += rewards[i].total_value;
    total_votes += poolShot[i];
  }
  console.log("└──────────────────────┴───────────────┴───────────────┴────────────┘");
  console.log("\nTotal Rewards:       $"+total_usd.toFixed(2));
  console.log("Total Votes:         "+total_votes.toFixed(2));
  console.log("Average $ per vote:  $"+(total_usd/total_votes).toFixed(5));
  if(proposal.end < Math.floor(Date.now()/1000)) {
    console.log("\nPlease note this proposal has already ended. Prices shown reflect the current token prices today, not the prices at the time of the proposal.");
  }
  process.exit();
}

main();
