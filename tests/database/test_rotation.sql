set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select public.v1_request_enrollment('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002',decode(repeat('66',32),'hex'),decode(repeat('77',32),'hex'));
select test.reject($q$select public.v1_approve_enrollment('a0000000-0000-0000-0000-000000000001',1,decode(repeat('33',32),'hex'),decode(repeat('66',32),'hex'),decode(repeat('88',32),'hex'),decode(repeat('99',92),'hex'))$q$,'enrollment_mismatch');
select public.v1_approve_enrollment('a0000000-0000-0000-0000-000000000001',1,decode(repeat('33',32),'hex'),decode(repeat('66',32),'hex'),decode(repeat('77',32),'hex'),decode(repeat('99',92),'hex'));
select test.assert(jsonb_array_length(public.v1_devices())=2,'second device approved with exact challenge');
select public.v1_rotate_keys('b0000000-0000-0000-0000-000000000001',1,decode(repeat('33',32),'hex'),decode(repeat('aa',32),'hex'),decode(repeat('bb',60),'hex'),array['10000000-0000-0000-0000-000000000001']::uuid[],
 jsonb_build_array(jsonb_build_object('device_id','10000000-0000-0000-0000-000000000002','envelope',decode(repeat('cc',92),'hex'))));
select test.reject($q$select public.v1_append_event('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000099',1,1,decode(repeat('55',60),'hex'),decode(repeat('33',32),'hex'))$q$,'key_authority_required');
select test.reject($q$select public.v1_append_event('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000099',2,1,decode(repeat('55',60),'hex'),decode(repeat('aa',32),'hex'))$q$,'key_authority_required');
select test.reject($q$select public.v1_append_event('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000099',1,1,decode(repeat('55',60),'hex'),decode(repeat('aa',32),'hex'))$q$,'stale_key_epoch');
select test.assert(public.v1_append_event('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000099',2,1,decode(repeat('55',60),'hex'),decode(repeat('aa',32),'hex'))=2,'surviving device writes with new epoch and authority');
select test.assert(public.v1_key_state('10000000-0000-0000-0000-000000000001')->>'device_envelope' is null,'revoked device receives no current envelope');
reset role;
