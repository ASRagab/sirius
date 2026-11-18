# Working memory cleanup

> What an agent does when asked to clean up working memory (`WMEM.md`). Shared by every agent; an agent's own `gc.md` in its registry folder takes its place. Edit `WMEM.md` directly; there is no tool for it.

## Goal

Working memory is the smallest set of pointers that lets a fresh session resolve what the user refers to ("the manifesto", "the D1 PDF", "the inference session") without searching or asking. Every entry costs prompt space in every session, so an entry stays only while it earns that.

## Steps

1. Read `WMEM.md`. The header gives the window in days and the date of the last cleanup.
2. Remove Learned entries you have no reason to think were used within the window. Never remove a Pinned entry; the user pins and unpins.
3. Check that what remains still holds: a path that no longer exists, or a session or window that is gone, is wrong rather than stale. Fix it if you know the new location, or remove it.
4. If the file is still over its token limit (`WMEM_TOKEN_LIMIT` in your `consts.md`, 2,000 tokens unless it says otherwise; a token is about 4 characters), remove the Learned entries least likely to be needed until it fits.
5. Set the header's `Cleaned:` date to today (`YYYY-MM-DD`).
6. Tell the user in one toast what you removed and what you fixed. If nothing changed, don't toast.

## Between cleanups

- When the user refers to something as familiar and you had to search or ask, add it once you have found it, as one line under Learned: `- name: where it is`. Names are short, lowercase and dashed. Entries point to things; they never hold the work itself.
- Add under Pinned only when the user asks for an entry to stay.
