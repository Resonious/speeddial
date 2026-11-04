import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/pull_request_status.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

PullRequestStatus status(
  PullRequestState state, {
  PullRequestChecks? checks,
  PullRequestReview? review,
}) => PullRequestStatus.of(
  SessionPullRequest(
    number: 12,
    url: 'https://github.com/org/repo/pull/12',
    state: state,
    checks: checks,
    review: review,
  ),
);

void main() {
  test('finished and draft pull requests read as their state', () {
    const PullRequestChecks failing = PullRequestChecks.failing;
    expect(
      status(PullRequestState.merged, checks: failing).label,
      '#12 merged',
    );
    expect(
      status(PullRequestState.closed, checks: failing).label,
      '#12 closed',
    );
    expect(status(PullRequestState.draft, checks: failing).label, '#12 draft');
  });

  test('an open pull request shows its most pressing fact', () {
    const PullRequestState open = PullRequestState.open;
    final PullRequestStatus failing = status(
      open,
      checks: PullRequestChecks.failing,
      review: PullRequestReview.approved,
    );
    expect(failing.label, '#12 failing');
    expect(failing.tone, PullRequestTone.failure);
    expect(
      status(
        open,
        checks: PullRequestChecks.pending,
        review: PullRequestReview.changesRequested,
      ).label,
      '#12 needs work',
    );
    expect(
      status(
        open,
        checks: PullRequestChecks.pending,
        review: PullRequestReview.approved,
      ).label,
      '#12 checking',
    );
    expect(
      status(
        open,
        checks: PullRequestChecks.passing,
        review: PullRequestReview.approved,
      ).label,
      '#12 approved',
    );
    expect(
      status(
        open,
        checks: PullRequestChecks.passing,
        review: PullRequestReview.reviewRequired,
      ).label,
      '#12 in review',
    );
    expect(
      status(open, checks: PullRequestChecks.passing).label,
      '#12 passing',
    );
    expect(status(open).label, '#12 open');
  });

  test('the tooltip gives the full picture while it still matters', () {
    expect(
      status(
        PullRequestState.open,
        checks: PullRequestChecks.failing,
        review: PullRequestReview.approved,
      ).tooltip,
      'Pull request #12: open · checks failing · approved',
    );
    expect(
      status(
        PullRequestState.merged,
        checks: PullRequestChecks.failing,
        review: PullRequestReview.approved,
      ).tooltip,
      'Pull request #12: merged',
    );
  });
}
