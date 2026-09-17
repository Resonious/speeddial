Run from `packages/daemon`:

```sh
dart run tool/benchmark_session_search.dart 10000 10
```

This creates and deletes a temporary database containing 10,000 sessions with
10 messages each, plus one session with 20,000 streamed chunks (about 205 MiB of
message text). It measures initial indexing, event-loop timer gaps, and 12 queries
of each kind, including the read isolate and result serialization into models.
It never connects to agents or touches an existing SpeedDial database.

On the development host, initial indexing took about 72–74 seconds. Subsequent
searches took about 7 ms median for a specific token, 2 ms for no matches, 55 ms
for a phrase present in every ordinary session (74 ms p95), and 9 ms for a phrase
repeated throughout the long streamed message. The largest observed gap in a
16 ms event-loop timer during backfill was 41–44 ms. This synthetic corpus uses
repeated text; timings are measurements, not fixed latency guarantees.

Substring indexing trades disk space for speed. This corpus produced a roughly
1 GiB database including the original events, searchable text blocks, and FTS
postings. Histories are indexed once, checkpoints survive restarts, and ongoing
streams update only bounded message tails. Broad queries first try a bounded
search in activity order and fall back to the inverted index when that cannot
establish a complete page. No query scans raw transcript JSON.
