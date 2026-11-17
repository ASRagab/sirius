# Working memory cleanup

> What an agent does when asked to clean up working memory (`WMEM.md`). Shared by every agent; an agent's own `gc.md` in its registry folder takes its place.

## Goal

Working memory is the smallest set of pointers that lets a fresh session resolve what the user refers to ("the manifesto", "the D1 PDF", "the inference session") without searching or asking. Every entry costs prompt space in every session, so an entry stays only while it earns that.

## Steps

1. Run `wmem ls`. It lists entries stalest first, with last use and hits, then the window, the file's size in tokens and any regrets since the last cleanup. A regret is an entry that was removed and then had to be added back.
2. Tune the window before using it. If there were regrets, add 7 days (`wmem window N`). If there were none and most Learned entries show no hits since the last cleanup, take 7 days off. Keep it between 7 and 28 days.
3. Remove Learned entries marked `STALE` (unused for longer than the window) with `wmem rm`. Never remove a Pinned entry; the user pins and unpins.
4. Check that what remains still holds: a path that no longer exists, or a session or window that is gone, is wrong rather than stale. Fix it with `wmem add` if you know the new location, or remove it.
5. If the file is still over its token limit (`WMEM_TOKEN_LIMIT` in your `consts.md`, 2,000 tokens unless it says otherwise), remove Learned entries in order of least recent use until it fits.
6. Run `wmem cleaned`.
7. Tell the user in one toast what you removed, what you fixed and the window, if it changed. If nothing changed, don't toast.

## Between cleanups

- When an entry resolves something the user refers to, run `wmem hit <name>`.
- When the user refers to something as familiar and you had to search or ask, add it once you have found it: `wmem add <name> <where it is>`. Names are short, lowercase and dashed. Entries point to things; they never hold the work itself.
- Use `--pin` only when the user asks for an entry to stay.
