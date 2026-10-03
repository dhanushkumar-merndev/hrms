import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/app/theme.dart';
import 'package:hrms/core/widgets/paged_list.dart';
import 'package:hrms/core/widgets/states.dart';

void main() {
  Widget testBed(Widget child) {
    return MaterialApp(
      theme: buildTheme(),
      home: Scaffold(body: child),
    );
  }

  group('Skeleton Shimmer Engine', () {
    testWidgets(
      'renders SkeletonShimmer with grey and dark tones without error',
      (tester) async {
        await tester.pumpWidget(
          testBed(
            const SkeletonShimmer(
              tone: SkeletonTone.grey,
              child: Column(
                children: [
                  SkeletonBone(width: 100, height: 20),
                  SkeletonAvatar(size: 40),
                  SkeletonLine(width: 80),
                  SkeletonChip(width: 60),
                  SkeletonTile(),
                ],
              ),
            ),
          ),
        );

        expect(find.byType(SkeletonShimmer), findsOneWidget);
        expect(find.byType(SkeletonBone), findsWidgets);
        expect(find.byType(SkeletonAvatar), findsWidgets);
        expect(find.byType(SkeletonLine), findsWidgets);
        expect(find.byType(SkeletonTile), findsOneWidget);

        // Advance animation frames to verify shimmer loop
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 700));

        // Test dark tone
        await tester.pumpWidget(
          testBed(
            const SkeletonShimmer(
              tone: SkeletonTone.dark,
              child: SkeletonCard(child: SkeletonLine(width: 100)),
            ),
          ),
        );
        expect(find.byType(SkeletonCard), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  });

  group('Screen-Specific Realistic Skeletons', () {
    testWidgets('HomeSkeleton mounts and renders UI-matching blocks', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const HomeSkeleton()));
      expect(find.byType(HomeSkeleton), findsOneWidget);
      expect(find.byType(SkeletonCard), findsWidgets);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets(
      'AttendanceSkeleton mounts and renders month bar and day rows',
      (tester) async {
        await tester.pumpWidget(testBed(const AttendanceSkeleton()));
        expect(find.byType(AttendanceSkeleton), findsOneWidget);
        expect(find.byType(SkeletonCard), findsWidgets);
        await tester.pump(const Duration(milliseconds: 400));
      },
    );

    testWidgets('LeaveSkeleton mounts and renders balance cards', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const LeaveSkeleton()));
      expect(find.byType(LeaveSkeleton), findsOneWidget);
      expect(find.byType(SkeletonCard), findsWidgets);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('PeopleSkeleton mounts and renders search and person tiles', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const PeopleSkeleton()));
      expect(find.byType(PeopleSkeleton), findsOneWidget);
      expect(find.byType(SkeletonTile), findsWidgets);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('ProfileSkeleton mounts and renders hero avatar card', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const ProfileSkeleton()));
      expect(find.byType(ProfileSkeleton), findsOneWidget);
      expect(find.byType(SkeletonAvatar), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('RequestsSkeleton and RequestDetailSkeleton mount cleanly', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const RequestsSkeleton()));
      expect(find.byType(RequestsSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(testBed(const RequestDetailSkeleton()));
      expect(find.byType(RequestDetailSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('PayslipsSkeleton and DocumentsSkeleton mount cleanly', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const PayslipsSkeleton()));
      expect(find.byType(PayslipsSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(testBed(const DocumentsSkeleton()));
      expect(find.byType(DocumentsSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('WorkspaceSkeleton and SettingsSkeleton mount cleanly', (
      tester,
    ) async {
      await tester.pumpWidget(testBed(const WorkspaceSkeleton()));
      expect(find.byType(WorkspaceSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(testBed(const SettingsSkeleton()));
      expect(find.byType(SettingsSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('AsyncView and PagedList Integration', () {
    testWidgets('AsyncView renders custom loading skeleton when loading', (
      tester,
    ) async {
      const asyncLoading = AsyncValue<String>.loading();
      await tester.pumpWidget(
        testBed(
          AsyncView<String>(
            value: asyncLoading,
            loading: const AttendanceSkeleton(),
            builder: (data) => Text(data),
          ),
        ),
      );

      expect(find.byType(AttendanceSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets(
      'AsyncView defaults to upgraded SkeletonList when loading is not specified',
      (tester) async {
        const asyncLoading = AsyncValue<String>.loading();
        await tester.pumpWidget(
          testBed(
            AsyncView<String>(
              value: asyncLoading,
              builder: (data) => Text(data),
            ),
          ),
        );

        expect(find.byType(SkeletonList), findsOneWidget);
        expect(find.byType(SkeletonShimmer), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
      },
    );

    testWidgets(
      'PagedList uses custom loading skeleton when initial page is fetching',
      (tester) async {
        await tester.pumpWidget(
          testBed(
            PagedList<String>(
              fetch: (_) async {
                // Never completing future during initial render
                return const PageResult([]);
              },
              loading: const PeopleSkeleton(),
              itemBuilder: (_, item) => Text(item),
            ),
          ),
        );

        expect(find.byType(PeopleSkeleton), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
      },
    );
  });
}
