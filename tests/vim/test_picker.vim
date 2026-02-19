" ============================================================================
" E2E Test: Picker — file search via Ctrl+P
" ============================================================================

call yac_test#begin('picker')
call yac_test#setup()

" Wait for daemon connection
sleep 1000m

" ============================================================================
" Test 1: YacPicker command exists
" ============================================================================
call yac_test#log('INFO', 'Test 1: YacPicker command exists')
call yac_test#assert_true(exists(':YacPicker'), 'YacPicker command should exist')

" ============================================================================
" Test 2: Picker open creates popups
" ============================================================================
call yac_test#log('INFO', 'Test 2: Picker open creates popups')

" Open the picker
YacPicker

" Wait for popup to appear
let popup_appeared = yac_test#wait_for('popup_list() != []', 3000)
call yac_test#assert_true(popup_appeared, 'Picker popups should appear')

" Check that we have at least one popup
let popups = popup_list()
call yac_test#assert_true(len(popups) >= 2, 'Should have at least 2 popups (input + results)')

" ============================================================================
" Test 3: Picker close via Esc
" ============================================================================
call yac_test#log('INFO', 'Test 3: Picker close via Esc')

" Close the picker
call feedkeys("\<Esc>", 'xt')
sleep 200m

" Verify popups are closed
let popups_after = popup_list()
call yac_test#assert_true(len(popups_after) == 0, 'All popups should be closed after Esc')

" ============================================================================
" Test 4: Picker toggle (open then open again closes)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Picker toggle')

YacPicker
let popup_appeared = yac_test#wait_for('popup_list() != []', 3000)
call yac_test#assert_true(popup_appeared, 'Picker should open')

" Call again to toggle off
call yac#picker_open()
sleep 200m

let popups_after = popup_list()
call yac_test#assert_true(len(popups_after) == 0, 'Picker should toggle off')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
