# paper_ex_polymarket test fixtures

Small, hand-authored fixtures modeling realistic Polymarket CLOB and
Data-API payload shapes. These exist to exercise the adapter against
the *shape* of real-world data without making network calls.

## Why hand-authored

`polymarket_clob/test/fixtures/parity/` contains v2 signing parity
fixtures (`clob_auth.json`, `l2_hmac.json`, `order_builder.json`,
`orders.json`) generated from `py-clob-client-v2`. None of them
describe CLOB `/book` responses or Data-API `/activity` events,
which are the shapes the adapter normalizes. Rather than introduce
a new fixture-generator dependency on `py-clob-client-v2`, this
package keeps its own small fixtures here.

Shapes mirror what the live v1 bot at `/Users/maxdon/Desktop/Elixir/polymarket_bot/`
actually consumes via `lib/polymarket_bot/clients/clob.ex` and
v1 RTDS / Data-API code. The price/size/timestamp encoding (decimal
strings; second- or millisecond-precision Unix timestamps) matches
that production source.

## Files

  * `clob_market.json` — `/markets/{conditionId}` style response: a
    Polymarket prediction market with a YES/NO token pair, tick
    size, neg-risk flag, and the `tokens` list the adapter uses to
    resolve outcome metadata.
  * `clob_book.json` — `/book?token_id={…}` style response: bids and
    asks as decimal-string `{price, size}` levels, plus the
    `market`/`asset_id`/`timestamp`/`tick_size` fields the adapter
    preserves into snapshot metadata.
  * `data_api_trade.json` — Data-API `/activity` style event for a
    single observed trade. Field names match the v1 bot's observed
    payloads: `asset`, `side`, `size`, `price`, `transactionHash`,
    `outcome`, `outcomeIndex`, `pseudonym`, `proxyWallet`,
    `conditionId`, `eventSlug`, `title`.

## Stability

Adapter normalization is field-name- and string-coercion-sensitive.
If a future Polymarket schema change adds or renames fields, update
these fixtures rather than the adapter's defensive parsers — the
fixtures are the contract the adapter is being tested against.
