import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failures.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';

/// Renders an [AsyncValue] with a consistent loading spinner and error card.
///
/// Every screen goes through this, so an offline cache miss, a rejected write
/// and a network timeout all look the same instead of each screen inventing its
/// own failure UI.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.loading,
    this.emptyBuilder,
    this.isEmpty,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;

  /// Shown instead of [builder] when [isEmpty] reports true for the data.
  final Widget Function()? emptyBuilder;
  final bool Function(T data)? isEmpty;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: value.when(
        loading: () =>
            loading ?? const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorCard(
          message: error is AppFailure ? error.userMessage : error.toString(),
          onRetry: onRetry,
        ),
        data: (data) {
          final empty = isEmpty?.call(data) ?? false;
          if (empty && emptyBuilder != null) return emptyBuilder!();
          return builder(data);
        },
      ),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 44, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Inline, dismissible message. Used for "queued while offline" style notices
/// that should not interrupt the user.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.message,
    this.tone = BannerTone.info,
    this.icon,
    this.action,
  });

  final String message;
  final BannerTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, defaultIcon) = switch (tone) {
      BannerTone.info => (scheme.primary, Icons.info_outline),
      BannerTone.warning => (
        context.appColors.warning,
        Icons.warning_amber_outlined,
      ),
      BannerTone.danger => (context.appColors.danger, Icons.error_outline),
      BannerTone.success => (
        context.appColors.success,
        Icons.check_circle_outline,
      ),
    };

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? defaultIcon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

enum BannerTone { info, warning, danger, success }

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Stock level pill. Turns amber at or below the low-stock threshold, which is
/// the whole point of having a threshold.
class StockBadge extends StatelessWidget {
  const StockBadge({
    super.key,
    required this.quantity,
    required this.unit,
    required this.isLow,
  });

  final num quantity;
  final String unit;
  final bool isLow;

  @override
  Widget build(BuildContext context) {
    final color = isLow ? context.appColors.warning : context.appColors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${formatQty(quantity)} $unit',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Small labelled pill used for project and cart statuses.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Shows how many writes are still queued for the server.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key, required this.pendingCount});

  final int pendingCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (pendingCount == 0) return const SizedBox.shrink();
    return Tooltip(
      message: '$pendingCount change${pendingCount == 1 ? '' : 's'} waiting to sync',
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Badge(
          label: Text('$pendingCount'),
          child: const Icon(Icons.cloud_upload_outlined),
        ),
      ),
    );
  }
}

/// Skeleton cards shown while a list-backed [AsyncView] is loading — calmer
/// than a bare spinner. Non-scrollable and shrink-wrapped so it also works
/// inside a [SectionCard] ([padding] zero there).
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({
    super.key,
    this.items = 4,
    this.cardHeight = 84,
    this.padding = const EdgeInsets.all(16),
  });

  final int items;
  final double cardHeight;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      itemCount: items,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) =>
          ShimmerBox(height: cardHeight, borderRadius: 14),
    );
  }
}

/// A labelled row used throughout the detail screens.
class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// Thin wrapper giving every screen's content the same padding and card style.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  trailing ?? const SizedBox.shrink(),
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// Animated placeholder used while a vendor price is being fetched (spec §5).
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = 6,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    final highlight = Theme.of(context).colorScheme.surfaceContainerLow;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              colors: [base, highlight, base],
              stops: [
                (t - 0.3).clamp(0.0, 1.0),
                t.clamp(0.0, 1.0),
                (t + 0.3).clamp(0.0, 1.0),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Yes/no confirmation for destructive actions.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Runs an async action, showing a snackbar with its failure message.
///
/// Returns true on success so callers can pop or refresh.
Future<bool> runGuarded(
  BuildContext context,
  Future<void> Function() action, {
  String? successMessage,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = context.appColors.danger;
  try {
    await action();
    if (successMessage != null) {
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    }
    return true;
  } on AppFailure catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(e.userMessage), backgroundColor: errorColor),
    );
    return false;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Something went wrong: $e'),
        backgroundColor: errorColor,
      ),
    );
    return false;
  }
}

/// [runGuarded] for actions that return something. Returns null on failure.
Future<T?> runGuardedValue<T>(
  BuildContext context,
  Future<T> Function() action, {
  String? successMessage,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = context.appColors.danger;
  try {
    final result = await action();
    if (successMessage != null) {
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    }
    return result;
  } on AppFailure catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(e.userMessage), backgroundColor: errorColor),
    );
    return null;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Something went wrong: $e'),
        backgroundColor: errorColor,
      ),
    );
    return null;
  }
}

/// One bottom-sheet helper for the whole app: scroll-controlled (keyboard
/// forms), inside the safe area, and capped so it does not stretch across a
/// desktop window.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 560,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxWidth: maxWidth),
    builder: (_) => child,
  );
}

/// Destructive menu entries get a consistent danger tint instead of looking
/// identical to "Edit".
PopupMenuItem<T> destructiveMenuItem<T>(
  T value,
  String label, {
  IconData icon = Icons.delete_outline,
}) {
  return PopupMenuItem<T>(
    value: value,
    child: Builder(
      builder: (context) => Row(
        children: [
          Icon(icon, size: 18, color: context.appColors.danger),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: context.appColors.danger)),
        ],
      ),
    ),
  );
}
