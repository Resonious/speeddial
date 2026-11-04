import 'package:speeddial_protocol/speeddial_protocol.dart';

/// What a pull request badge's color should say. Each surface maps this to
/// its own palette.
enum PullRequestTone { neutral, active, attention, failure, success, merged }

/// A pull request's status reduced to one short badge: the thing most worth
/// knowing at a glance, with the full picture in [tooltip].
class PullRequestStatus {
  const PullRequestStatus._(this.label, this.tooltip, this.tone);

  factory PullRequestStatus.of(SessionPullRequest pr) {
    final (String word, PullRequestTone tone) = _headline(pr);
    final List<String> details = <String>[
      pr.state.name,
      if (pr.state == PullRequestState.open ||
          pr.state == PullRequestState.draft) ...<String>[
        ?_checksDetail(pr.checks),
        ?_reviewDetail(pr.review),
      ],
    ];
    return PullRequestStatus._(
      '#${pr.number} $word',
      'Pull request #${pr.number}: ${details.join(' · ')}',
      tone,
    );
  }

  final String label;
  final String tooltip;
  final PullRequestTone tone;

  /// Blockers come first: a failing or rejected pull request reads that way
  /// whatever else is true of it.
  static (String, PullRequestTone) _headline(SessionPullRequest pr) {
    switch (pr.state) {
      case PullRequestState.merged:
        return ('merged', PullRequestTone.merged);
      case PullRequestState.closed:
        return ('closed', PullRequestTone.neutral);
      case PullRequestState.draft:
        return ('draft', PullRequestTone.neutral);
      case PullRequestState.open:
        break;
    }
    if (pr.checks == PullRequestChecks.failing) {
      return ('failing', PullRequestTone.failure);
    }
    if (pr.review == PullRequestReview.changesRequested) {
      return ('needs work', PullRequestTone.attention);
    }
    if (pr.checks == PullRequestChecks.pending) {
      return ('checking', PullRequestTone.active);
    }
    if (pr.review == PullRequestReview.approved) {
      return ('approved', PullRequestTone.success);
    }
    if (pr.review == PullRequestReview.reviewRequired) {
      return ('in review', PullRequestTone.active);
    }
    if (pr.checks == PullRequestChecks.passing) {
      return ('passing', PullRequestTone.success);
    }
    return ('open', PullRequestTone.active);
  }

  static String? _checksDetail(PullRequestChecks? checks) => switch (checks) {
    PullRequestChecks.passing => 'checks passing',
    PullRequestChecks.failing => 'checks failing',
    PullRequestChecks.pending => 'checks running',
    null => null,
  };

  static String? _reviewDetail(PullRequestReview? review) => switch (review) {
    PullRequestReview.approved => 'approved',
    PullRequestReview.changesRequested => 'changes requested',
    PullRequestReview.reviewRequired => 'review required',
    null => null,
  };
}
