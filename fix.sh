#!/bin/bash
set -e

BRANCH=$(git branch --show-current)
ORIGINAL_TESTS=(
  test/async_test.dart test/bridge_test.dart test/class_test.dart
  test/collection_test.dart test/convert_test.dart test/datetime_test.dart
  test/diagnostic_mode_test.dart test/enum_test.dart test/exception_test.dart
  test/expression_test.dart test/field_test.dart test/function_test.dart
  test/functional1_test.dart test/loop_test.dart test/not_equal_test.dart
  test/operator_test.dart test/pattern_test.dart test/postfix_test.dart
  test/prefix_test.dart test/prefixed_import_test.dart test/records_test.dart
  test/regexp_test.dart test/set_test.dart test/stdlib_test.dart
  test/string_test.dart test/switch_test.dart test/tearoff_test.dart
  test/uri_test.dart test/variable_test.dart test/wrap_test.dart
)

case "$1" in
  new)
    [ -z "$2" ] && echo "Usage: ./fix.sh new <branch-name>" && exit 1
    git checkout -b "$2" master
    echo "Branch '$2' created from master"
    ;;

  bug)
    [ -z "$2" ] || [ -z "$3" ] && echo "Usage: ./fix.sh bug <test-file> <pattern>" && exit 1
    TEST_FILE="$2"
    PATTERN="$3"

    echo "=== Verifying test fails on master ==="
    cp "$TEST_FILE" /tmp/_fix_test.dart
    git stash -q 2>/dev/null || true
    git checkout master -q

    if fvm dart test /tmp/_fix_test.dart --name "$PATTERN" 2>&1 | grep -q "\[E\]"; then
      echo "✓ Test fails on master (bug confirmed)"
    else
      echo "✗ Test passes on master — not a real bug"
      git checkout "$BRANCH" -q
      git stash pop -q 2>/dev/null || true
      exit 1
    fi

    git checkout "$BRANCH" -q
    git stash pop -q 2>/dev/null || true

    echo ""
    echo "Create /tmp/real_test.dart with the same logic, then run:"
    echo "  fvm dart run /tmp/real_test.dart"
    ;;

  check)
    [ -z "$2" ] || [ -z "$3" ] && echo "Usage: ./fix.sh check <test-file> <pattern>" && exit 1
    TEST_FILE="$2"
    PATTERN="$3"

    echo "=== 1. Test passes with fix ==="
    if fvm dart test "$TEST_FILE" --name "$PATTERN" 2>&1 | grep -q "All tests passed"; then
      echo "✓ Test passes"
    else
      echo "✗ Test fails — fix doesn't work"
      exit 1
    fi

    echo ""
    echo "=== 2. Test fails on master ==="
    cp "$TEST_FILE" /tmp/_fix_test.dart
    git stash -q 2>/dev/null || true
    git checkout master -q

    if fvm dart test /tmp/_fix_test.dart --name "$PATTERN" 2>&1 | grep -q "\[E\]"; then
      echo "✓ Test fails on master (regression confirmed)"
    else
      echo "✗ Test passes on master — test doesn't catch the bug"
      git checkout "$BRANCH" -q
      git stash pop -q 2>/dev/null || true
      exit 1
    fi

    git checkout "$BRANCH" -q
    git stash pop -q 2>/dev/null || true

    echo ""
    echo "=== 3. No regressions ==="
    EXISTING=""
    for f in "${ORIGINAL_TESTS[@]}"; do
      [ -f "$f" ] && EXISTING="$EXISTING $f"
    done

    RESULT=$(fvm dart test $EXISTING 2>&1 | tail -1)
    if echo "$RESULT" | grep -q "All tests passed"; then
      echo "✓ $RESULT"
    else
      echo "✗ Regressions detected:"
      fvm dart test $EXISTING 2>&1 | grep "\[E\]"
      exit 1
    fi

    echo ""
    echo "All checks passed. Run: ./fix.sh ship \"fix: description\""
    ;;

  ship)
    [ -z "$2" ] && echo "Usage: ./fix.sh ship <commit-message>" && exit 1
    MESSAGE="$2"

    echo "=== Staging and committing ==="
    git add -u
    git diff --cached --name-only | head -20
    git commit -m "$MESSAGE"

    echo ""
    echo "=== Pushing ==="
    git push origin "$BRANCH"

    echo ""
    echo "=== PR ==="
    PR_FILE="/tmp/dart_eval_pr.txt"
    TEST_COUNT=$(git diff HEAD~1 -- 'test/*.dart' | grep -c "test(" || echo 0)
    cat > "$PR_FILE" << EOF
Title: $MESSAGE

Body:
<FILL IN 1-2 SENTENCES>

$TEST_COUNT regression test(s).
EOF
    echo "PR template written to $PR_FILE"
    cat "$PR_FILE"
    echo ""
    echo "Create PR at: https://github.com/khoadng/dart_eval/pull/new/$BRANCH"

    echo ""
    echo "=== Cherry-picking to dev ==="
    COMMIT=$(git rev-parse HEAD)
    git checkout dev -q
    if git cherry-pick "$COMMIT" 2>/dev/null; then
      echo "✓ Cherry-picked to dev"
      git checkout "$BRANCH" -q
    else
      echo "✗ Cherry-pick conflict — resolve manually:"
      echo "  git status"
      echo "  # fix conflicts, then:"
      echo "  git add <files> && git cherry-pick --continue"
      echo "  git checkout $BRANCH"
    fi
    ;;

  *)
    echo "dart_eval bug fix workflow"
    echo ""
    echo "  ./fix.sh new <branch>              Branch from master"
    echo "  ./fix.sh bug <file> <pattern>      Verify bug (fails on master)"
    echo "  ./fix.sh check <file> <pattern>    Verify fix (passes, no regressions)"
    echo "  ./fix.sh ship <message>            Commit, push, cherry-pick to dev"
    ;;
esac
