_default:
  @just --list

# Install the project dependencies
get-dependencies:
  dart pub get

# Analyze the project
lint:
  dart format --set-exit-if-changed .
  dart analyze .
  sqlfluff lint

# Generate test entrypoint
generate-test-entrypoints:
  dart run tool/generate_test_entrypoints.dart
  dart format test/_test.dart

# Runs all tests (with coverage)
test: generate-test-entrypoints
  dart test test/_test.dart --test-randomize-ordering-seed=random --coverage coverage
  dart run coverage:format_coverage --lcov --report-on lib --check-ignore -i coverage/test/_test.dart.vm.json -o coverage/lcov.info

# Start Supabase for local development or testing
start-supabase:
  supabase start -x=storage-api,imgproxy,mailpit,logflare,vector,edge-runtime

# Generate code
generate-code:
  dart run build_runner build --delete-conflicting-outputs
  dart format test/utils/test_mocks.mocks.dart
