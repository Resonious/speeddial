import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// A bounded, scrollable form for an agent's structured questions.
class QuestionBanner extends StatefulWidget {
  const QuestionBanner({
    super.key,
    required this.request,
    required this.onSubmit,
  });

  final PermissionRequest request;
  final Future<void> Function(List<UserQuestionAnswer>? answers) onSubmit;

  @override
  State<QuestionBanner> createState() => _QuestionBannerState();
}

class _QuestionBannerState extends State<QuestionBanner> {
  late final _Answers model = _Answers(widget.request.questions);

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  Future<void> _submit({bool skip = false}) async {
    model.busy = true;
    model.error = null;
    model.changed();
    try {
      await widget.onSubmit(skip ? null : model.answers());
    } on Object catch (error) {
      if (mounted) {
        model.error = error is DaemonError ? error.message : '$error';
      }
    } finally {
      if (mounted) {
        model.busy = false;
        model.changed();
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Card(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              (MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom) *
              0.45,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < model.questions.length; i++) ...<Widget>[
                Text(
                  model.questions[i].header,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(model.questions[i].question),
                if (model.questions[i].multiSelect)
                  const Text('Select all that apply'),
                for (final option in model.questions[i].options)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(option.label),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (option.description.isNotEmpty)
                          Text(option.description),
                        if (option.preview != null) Text(option.preview!),
                      ],
                    ),
                    value: model.selected[i].contains(option.label),
                    onChanged: model.busy
                        ? null
                        : (value) =>
                              model.select(i, option.label, value ?? false),
                  ),
                TextField(
                  controller: model.notes[i],
                  enabled: !model.busy,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Your answer or additional details',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (model.error != null)
                Text(
                  model.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: model.busy ? null : _submit,
                    child: const Text('Submit answers'),
                  ),
                  TextButton(
                    onPressed: model.busy ? null : () => _submit(skip: true),
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Answers extends ChangeNotifier {
  _Answers(this.questions)
    : selected = [for (final _ in questions) <String>{}],
      notes = [for (final _ in questions) TextEditingController()];

  final List<UserQuestion> questions;
  final List<Set<String>> selected;
  final List<TextEditingController> notes;
  bool busy = false;
  String? error;

  void changed() => notifyListeners();

  void select(int index, String label, bool value) {
    if (!questions[index].multiSelect) selected[index].clear();
    if (value) {
      selected[index].add(label);
    } else {
      selected[index].remove(label);
    }
    notifyListeners();
  }

  List<UserQuestionAnswer> answers() => [
    for (var i = 0; i < questions.length; i++)
      UserQuestionAnswer(
        selected: [
          for (final option in questions[i].options)
            if (selected[i].contains(option.label)) option.label,
        ],
        note: notes[i].text.trim().isEmpty ? null : notes[i].text.trim(),
      ),
  ];

  @override
  void dispose() {
    for (final controller in notes) {
      controller.dispose();
    }
    super.dispose();
  }
}
