#!/bin/sh

test_description='merge-base on a commit graph with inconsistent generation numbers

Commits with a committer date of 2^32+ seconds caused prior Git versions [1] to
write commit graphs in which generation numbers were not strictly monotonically
increasing from parents to children.

The early-termination optimization in paint_down_to_common() relies on that
invariant when traversing the commit graph. When working with an inconsistent
commit graph, this reliance unfortunately triggers a BUG().

While newer Git versions no longer produce inconsistent commit graphs, many
repositories still have problematic commit graphs in the wild that were
written by older versions and not yet rewritten by maintenance. For this reason,
we need to gracefully handle inconsistent commit graphs for an indeterminate
amount of time, which is what this test file covers.

Git no longer writes inconsistent generation numbers, so this test constructs
one by writing a correct commit graph and then patching its GDA2 chunk. It then
checks that git merge-base degrades gracefully (falling back to the unoptimized
walk) instead of crashing.

[1] Fixed in fbcc5408fcd60206234ba26cc103ef2757532ae0
'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-chunk.sh

# The setup builds the linear history
#
#	future-ancestor (committer date 2^32) <- middle <- tip
#
# and corrupts the commit graph so that middle gets a lower generation number
# than future-ancestor. In this way, middle is incorrectly pruned, reproducing
# the behavior of prior Git versions. tip is two commits from future-ancestor
# so that the generation-number cutoff has middle in between to prune.
#
# future-ancestor is an ancestor of tip, so it is their only merge base.

test_expect_success PERL_TEST_HELPERS,TIME_IS_64BIT,TIME_T_IS_64BIT 'set up repository with an inconsistent generation number' '
	overflow_epoch=$((1 << 32)) &&

	git init repo &&
	(
		cd repo &&

		GIT_AUTHOR_DATE="@$overflow_epoch +0000" &&
		GIT_COMMITTER_DATE="@$overflow_epoch +0000" &&
		export GIT_AUTHOR_DATE GIT_COMMITTER_DATE &&
		git commit --allow-empty -m future-ancestor &&
		git tag future-ancestor &&

		GIT_AUTHOR_DATE="2000-01-01 00:00:00 +0000" &&
		GIT_COMMITTER_DATE="2000-01-01 00:00:00 +0000" &&
		export GIT_AUTHOR_DATE GIT_COMMITTER_DATE &&
		git commit --allow-empty -m middle &&

		GIT_AUTHOR_DATE="2000-01-02 00:00:00 +0000" &&
		GIT_COMMITTER_DATE="2000-01-02 00:00:00 +0000" &&
		export GIT_AUTHOR_DATE GIT_COMMITTER_DATE &&
		git commit --allow-empty -m tip &&
		git tag tip &&

		git commit-graph write --reachable &&

		# Git now writes consistent commit graphs, so simulate the old
		# behavior by patching the GDA2 chunk to zero the generation
		# number of the middle commit. The chunk stores one big-endian
		# 4-byte value per commit, in the same order as the OID lookup
		# table.
		git rev-parse HEAD^ >middle.oid &&
		git rev-list --all | sort >oids &&
		idx=$(grep -n -f middle.oid oids | cut -d: -f1) &&
		corrupt_chunk_file .git/objects/info/commit-graph \
			GDA2 $(( (idx - 1) * 4 )) "00000000" &&

		# Verify that the inconsistency is reported as a warning.
		test_must_fail git commit-graph verify 2>verify.err &&
		test_grep "generation for commit" verify.err
	)
'

test_expect_success PERL_TEST_HELPERS,TIME_IS_64BIT,TIME_T_IS_64BIT 'merge-base --all does not abort' '
	(
		cd repo &&
		git rev-parse future-ancestor >expect &&
		git merge-base --all future-ancestor tip >actual &&
		test_cmp expect actual
	)
'

test_done
