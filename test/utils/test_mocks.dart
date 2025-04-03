import 'package:http/http.dart';
import 'package:mockito/annotations.dart';
import 'package:supabase/supabase.dart';

@GenerateNiceMocks([MockSpec<SupabaseClient>()])
@GenerateNiceMocks([MockSpec<SupabaseQueryBuilder>()])
@GenerateNiceMocks([MockSpec<RealtimeChannel>()])
@GenerateNiceMocks([MockSpec<Client>()])
void main() {}
