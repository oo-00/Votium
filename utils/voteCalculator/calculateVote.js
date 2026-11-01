// Votium vote calculator: a round's incentives, votes and $ per vlCVX on each gauge, at today's prices.
// Deposits, votes, opt-outs and prices come from votium.js (github.com/oo-00/votium.js), and what each deposit pays
// from its caps.js, Votium's maxPerVote rules (README.md, "How it counts").
//
//   RPC_URL=<mainnet RPC> node calculateVote.js [--fxn] [--round N] [--deposits] [--storage DIR]

const path = require("path");
const ethers = require("ethers");
const { roundEpoch } = require("votium.js/rounds.js");
const { paidOut, stackedRound, STACKED_FROM } = require("votium.js/caps.js");

const MARKETS = {
    curve: { platform: 0, name: "Curve", onchainFrom: 128 },
    fxn: { platform: 2, name: "f(x)", onchainFrom: 63 },
};
const VOTE_DAYS = 5;

const USAGE = `Usage: RPC_URL=<mainnet RPC> node calculateVote.js [options]

  --fxn          f(x) gauges (default: Curve)
  --round N      round N (default: the current round)
  --deposits     list each deposit under its gauge
  --storage DIR  where votium.js caches what it reads (default: ./storage)`;

function options(argv) {
    const out = { market: "curve", round: 0, deposits: false, storage: path.join(__dirname, "storage") };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a == "--fxn") { out.market = "fxn"; }
        else if (a == "--curve") { out.market = "curve"; }
        else if (a == "--round") { out.round = Number(argv[++i]); }
        else if (a == "--deposits") { out.deposits = true; }
        else if (a == "--storage") { out.storage = argv[++i]; }
        else if (a == "--help" || a == "-h") { out.help = true; }
        else { throw new Error("unknown option " + a + "\n\n" + USAGE); }
    }
    if (!Number.isInteger(out.round) || out.round < 0) { throw new Error("--round takes a round number\n\n" + USAGE); }
    if (!out.storage) { throw new Error("--storage takes a folder\n\n" + USAGE); }
    return out;
}

// A round's gauges: incentives, paid, votes, earning votes and $/vlCVX, with each deposit's figures
async function calculate(votium, market, round) {
    const platform = market.platform;
    await votium.updateGauges(platform); // names gauges; refreshed from the market's API when 8 hours old
    const incentives = await votium.getIncentivesByRound(round, platform);
    const byGauge = (incentives && incentives.mainnet) || {};

    // votes: the current round is re-tallied when its tally is 15 minutes old, a finished one once
    const shot = await votium.updateSnapshot(round, 60 * 15, platform);
    const votes = shot && shot.votes && shot.votes.gauges;
    const voteOf = {};
    for (const g in votes || {}) { voteOf[g.toLowerCase()] = votes[g]; }
    const withheld = votes ? await votium.withheldWeights(round, platform, Object.keys(votes)) : {};
    const withheldOf = {};
    for (const g in withheld) { withheldOf[g.toLowerCase()] = withheld[g]; }

    const tokens = new Set();
    for (const g in byGauge) { for (const d of byGauge[g]) { tokens.add(d.token); } }
    const prices = tokens.size ? await votium.prices([...tokens]) : {};
    const unpriced = new Set();
    const usd = (d, raw) => {
        const price = Number(prices[ethers.getAddress(d.token)]);
        if (!(price >= 0) || d.decimalsUnknown) { unpriced.add(d.symbol || d.token); return 0; }
        return Number(ethers.formatUnits(raw, d.decimals)) * price;
    };

    const stacked = stackedRound(round, platform);
    const gauges = [];
    for (const g in byGauge) {
        const deposits = byGauge[g];
        if (deposits.length == 0) { continue; }
        const vote = voteOf[g.toLowerCase()] || { total: 0 };
        const withheldHere = Math.min(vote.total, withheldOf[g.toLowerCase()] || 0);
        const earning = vote.total - withheldHere;
        const paid = paidOut(deposits, Math.ceil(earning), stacked); // earning votes rounded up, as reconcile submits them
        const rows = deposits.map((d, i) => ({
            index: Number(d.index), symbol: d.symbol, token: d.token, decimals: d.decimals, decimalsUnknown: !!d.decimalsUnknown,
            amount: BigInt(d.amount), maxPerVote: BigInt(d.maxPerVote), paid: paid[i],
            usd: usd(d, d.amount), paidUsd: usd(d, paid[i]),
        }));
        const incentivesUsd = rows.reduce((t, r) => t + r.usd, 0);
        const paidUsd = rows.reduce((t, r) => t + r.paidUsd, 0);
        gauges.push({
            gauge: g, name: deposits[0].pool, votes: vote.total, withheld: withheldHere, earning,
            incentivesUsd, paidUsd, perVlCVX: earning > 0 ? paidUsd / earning : null, deposits: rows,
        });
    }
    gauges.sort((a, b) => (b.perVlCVX || 0) - (a.perVlCVX || 0) || b.incentivesUsd - a.incentivesUsd);
    return { round, market, stacked, voted: votes != null && Object.keys(votes).length > 0, gauges, unpriced: [...unpriced] };
}

// display

const money = (x) => "$" + x.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const count = (x) => x.toLocaleString("en-US", { maximumFractionDigits: 2 });
const rate = (x) => (x == null ? "-" : "$" + (x >= 0.01 ? x.toFixed(4) : x.toPrecision(3))); // f(x) pays about $0.0002
// token amounts to 2 decimals, or 4 significant digits under 1 (a cap of 0.008 per vote)
const tokenAmount = (raw, r) => {
    if (r.decimalsUnknown) { return raw.toString() + " (base units)"; }
    const x = Number(ethers.formatUnits(raw, r.decimals));
    return x != 0 && Math.abs(x) < 1 ? x.toLocaleString("en-US", { maximumSignificantDigits: 4 }) : count(x);
};
const day = (t) => new Date(t * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";

// rows of cells as a box table: the first column left-aligned, the others right-aligned
function table(header, rows) {
    const widths = header.map((h, j) => Math.max(h.length, ...rows.map((r) => String(r[j]).length)));
    const line = (l, m, r) => l + widths.map((w) => "─".repeat(w + 2)).join(m) + r;
    const row = (cells) => "│" + cells.map((c, j) => " " + (j == 0 ? String(c).padEnd(widths[j]) : String(c).padStart(widths[j])) + " ").join("│") + "│";
    return [line("┌", "┬", "┐"), row(header), line("├", "┼", "┤"), ...rows.map(row), line("└", "┴", "┘")].join("\n");
}

function show(result, listDeposits) {
    const { round, market, gauges } = result;
    const start = roundEpoch(round, market.platform);
    const now = Math.floor(Date.now() / 1000);
    const when = now < start ? "the vote starts " + day(start)
        : now < start + VOTE_DAYS * 86400 ? "the vote is open, from " + day(start)
        : "voted from " + day(start);
    console.log("\n" + market.name + " round " + round + ": " + when + "\n");

    if (gauges.length == 0) {
        console.log("No deposits for this round yet.");
        return;
    }
    // before the vote, only what's deposited
    const voted = result.voted;
    console.log(voted
        ? table(["Gauge", "Incentives", "Paid", "Votes", "Earning votes", "$/vlCVX"],
            gauges.map((g) => [g.name, money(g.incentivesUsd), money(g.paidUsd), count(g.votes), count(g.earning), rate(g.perVlCVX)]))
        : table(["Gauge", "Incentives"], gauges.map((g) => [g.name, money(g.incentivesUsd)])));

    if (listDeposits) {
        console.log("\nDeposits");
        for (const g of gauges) {
            console.log("  " + g.name + " (" + g.gauge + ")");
            for (const d of g.deposits) {
                const cap = d.maxPerVote > 0n ? ", max " + tokenAmount(d.maxPerVote, d) + " per vlCVX" : "";
                const kept = d.amount - d.paid;
                console.log("    #" + d.index + "  " + tokenAmount(d.amount, d) + " " + d.symbol + cap + " (" + money(d.usd) + ")"
                    + (voted ? ": pays " + tokenAmount(d.paid, d) + (kept > 0n ? ", " + tokenAmount(kept, d) + " not paid" : "") : ""));
            }
        }
    }

    const sum = (list, f) => list.reduce((t, g) => t + f(g), 0);
    const incentivesUsd = sum(gauges, (g) => g.incentivesUsd);
    const deposits = sum(gauges, (g) => g.deposits.length);
    const say = (label, value) => console.log((label + ":").padEnd(25) + value);
    console.log("");
    say("Incentives", money(incentivesUsd) + " in " + deposits + " deposit" + (deposits == 1 ? "" : "s") + " on " + gauges.length + " gauge" + (gauges.length == 1 ? "" : "s"));
    if (!voted) {
        say("Votes", "none yet");
    } else {
        const paidUsd = sum(gauges, (g) => g.paidUsd);
        const earning = sum(gauges, (g) => g.earning);
        const withheld = sum(gauges, (g) => g.withheld);
        const rates = gauges.filter((g) => g.perVlCVX != null).map((g) => g.perVlCVX).sort((a, b) => a - b);
        const noVotesUsd = sum(gauges.filter((g) => g.earning == 0), (g) => g.incentivesUsd);
        const heldUsd = incentivesUsd - paidUsd - noVotesUsd;
        say("Paid to voters", money(paidUsd));
        if (heldUsd >= 0.005) { say("Held back by caps", money(heldUsd)); }
        if (noVotesUsd > 0) { say("On gauges no one earns", money(noVotesUsd) + " (not paid; the depositors can withdraw it)"); }
        say("Votes on these gauges", count(sum(gauges, (g) => g.votes)) + (withheld > 0 ? ", " + count(withheld) + " of them opted out" : ""));
        say("Earning votes", count(earning));
        say("Average $ per vlCVX", rate(earning > 0 ? paidUsd / earning : null));
        say("Median $ per vlCVX", rate(rates.length ? rates[Math.floor(rates.length / 2)] : null));
    }

    console.log("\nCaps: " + (result.stacked
        ? "capped deposits stack per token, highest cap first. What the contract releases of one but voters aren't paid goes back to its depositor; the rest rolls over to the next round."
        : "each capped deposit pays min(amount, max per vote × earning votes); the rest rolls over to the next round. (Caps stack per token from " + market.name + " round " + STACKED_FROM[market.platform] + ".)"));
    console.log("Prices are today's" + (now >= start + VOTE_DAYS * 86400 ? ", not those at the time of this round's vote" : "") + ".");
    if (result.unpriced.length) { console.log("No price for " + result.unpriced.join(", ") + ": counted as $0."); }
}

async function main() {
    const opts = options(process.argv.slice(2));
    if (opts.help) { console.log(USAGE); return; }
    if (!process.env.RPC_URL) { throw new Error("Set RPC_URL to a mainnet RPC URL.\n\n" + USAGE); }
    const market = MARKETS[opts.market];
    const votium = require("votium.js")({
        providers: { mainnet: process.env.RPC_URL },
        storage: require("votium.js/storage/local.js")(opts.storage),
    });
    const round = opts.round || votium.round(market.platform);
    if (round < market.onchainFrom) {
        throw new Error(market.name + " round " + round + " was voted on Snapshot. This calculator covers on-chain rounds: "
            + market.name + " round " + market.onchainFrom + " on.");
    }
    show(await calculate(votium, market, round), opts.deposits);
}

module.exports = { calculate };

if (require.main === module) {
    main().then(() => process.exit(0), (e) => { console.error(e.message || e); process.exit(1); });
}
