# Vote calculator

Prints a Votium round's incentives, votes and $ per vlCVX for each gauge, at today's prices. Curve and f(x)
rounds voted on-chain (Curve round 128 on, f(x) round 63 on). Deposits, votes, opt-outs and prices come from
[votium.js](https://github.com/oo-00/votium.js) 2.3.0, and what each deposit pays from its `caps.js`.

## Run

Node 18 or later.

```sh
npm i
RPC_URL=<mainnet RPC URL> node calculateVote.js
```

| Option | |
|---|---|
| `--fxn` | f(x) gauges (default: Curve) |
| `--round N` | round N (default: the current round) |
| `--deposits` | list each deposit under its gauge: amount, max per vote, what it pays |
| `--storage DIR` | where votium.js caches what it reads (default: `./storage`) |

The first run reads the last 20 weeks of vlCVX lock events to find who delegates (about 100 log queries, so a
minute or two). It's cached in `./storage`, and later runs only read what's new. A finished round's votes are
tallied once and kept. The current round's are tallied again when the stored tally is 15 minutes old.

## How it counts

- **Votes** are counted on-chain, with delegated vlCVX credited to each delegator, as Votium's reconcile counts them.
- **Earning votes** are a gauge's votes less the vlCVX that opt-outs withhold there. Opted-out voters earn
  nothing on that gauge and don't dilute anyone.
- **Uncapped deposits** pay in full, split over the gauge's earning votes.
- **Capped deposits** (a max per vote, in the deposit's token):
  - From Curve round 135 and f(x) round 70, caps stack per token. A capped deposit isn't used until the gauge's
    other rewards in that token are diluted below its cap. Then it holds that token's rate at its cap until it
    runs out. With several caps in one token, the highest goes first. The deposit contract releases at most
    max per vote × earning votes of a capped deposit. Whatever voters aren't paid out of that goes back to the
    depositor, and the rest rolls over to the next round.
  - Before those rounds, each capped deposit paid min(amount, max per vote × earning votes) on its own, and the
    rest rolled over.
- Earning votes are rounded up for the cap, as reconcile submits them.
- **A gauge with no earning votes** pays nothing. Its depositors can withdraw their deposits after the round.
- **$ per vlCVX** for a gauge is what it pays ÷ its earning votes. The average is the total paid ÷ all those
  gauges' earning votes, and the median is taken over the gauges with earning votes.
- **Prices** come from DefiLlama, today's. A finished round is shown at today's prices, not those at its vote.
  A token without a price counts as $0, and the output names it.
