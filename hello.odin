package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Run with: odin run hello.odin -file -debug

// BUGS:
// [FIXED in ODIN] slicing out of bounds just causes a crash - exit code is thrown
// * when taking a val of out map, it must be pointer referenced in cases for it's another map
// 		* otherwise, you'll get an infinite loop if you try to add keys to it (in the case of a map)
// [FIXED in ODIN] STDERR wasn't working: https://github.com/odin-lang/Odin/pull/3258

SCREEN_WIDTH :: 1200
SCREEN_HEIGHT :: 758
SCREEN_MARGIN :: 30

TOTAL_QUESTIONS :: 5

pix_font: rl.Font
pause := false

Deck :: struct {
	subject:               string,
	transmission:          string,
	microbe_form:          string,
	signs_symptoms:        string,
	nursing_interventions: string,
	complications:         string,
	vaccine_available:     string,
}

Doc :: struct {
	name:  string,
	class: string,
	date:  string,
	decks: [dynamic]map[string]string,
}

doc_destroy :: proc(d: ^Doc) {
	for item in d.decks {
		for k, v in item {
			delete(k)
			delete(v)
		}
		delete(item)
	}

	delete(d.name)
	delete(d.class)
	delete(d.date)
	delete(d.decks)
}


State :: enum {
	Answering,
	Grading,
	Intermission,
	End,
}

Mode :: enum {
	Fresh, // all fresh questions
	Review, // reviewing previous questions
}

Game :: struct {
	state:           State,
	doc:             ^Doc,
	//question:        ^Question,
	question_number: int,
	correct:         int,
	incorrect:       int,
	paused:          bool,
	card:            Card,
	question_bank:   [dynamic]^Question,
	super_set:       map[string]map[string]bool,
	user_quit:       bool,
	user_mode:       Mode,
}

destroy_game :: proc(g: ^Game) {
	for q in g.question_bank {
		destroy_question(q)
	}
	delete(g.question_bank)
}

Card :: struct {
	count:        int,
	question:     string,
	proposed:     [4]string,
	user_answers: [4]bool,
}

// TODO: now that stderr works, get rid of this nonsense.
boom :: proc(txt: string) {
	fmt.printf("ERROR: %s\n", txt)
	// No idea why panic text doesn't show up, but at least it stops the program.
	panic(txt)
}

tcstring :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}


start_tracking_allocator :: proc() -> mem.Allocator {
	ta := new(mem.Tracking_Allocator)
	mem.tracking_allocator_init(ta, context.allocator)
	return mem.tracking_allocator(ta)
}

finish_tracking_allocator :: proc() {
	ta: ^mem.Tracking_Allocator = cast(^mem.Tracking_Allocator)context.allocator.data

	all_clear := true
	if len(ta.allocation_map) > 0 {
		fmt.eprintf("=== %v allocations not freed: ===\n", len(ta.allocation_map))
		for _, entry in ta.allocation_map {
			fmt.eprintf("❌ - %v bytes @ %v\n", entry.size, entry.location)
		}
		all_clear = false
	}
	if len(ta.bad_free_array) > 0 {
		fmt.eprintf("=== %v incorrect frees: ===\n", len(ta.bad_free_array))
		for entry in ta.bad_free_array {
			fmt.eprintf("❌ - %p @ %v\n", entry.memory, entry.location)
		}
		all_clear = false
	}
	mem.tracking_allocator_destroy(ta)
	if all_clear {
		fmt.eprintln("✅ - no leaks found")
	}
}

main :: proc() {
	when ODIN_DEBUG {
		fmt.println("Odin in debug mode.")

		context.allocator = start_tracking_allocator()
		defer finish_tracking_allocator()
		_real_main()
	} else {
		_real_main()
	}
}

_real_main :: proc() {
	d: Doc
	fmt.println("decks->", d.decks == nil)
	g := new(Game)
	g.doc = &d
	defer free(g)
	g.super_set = make(map[string]map[string]bool)
	defer {
		for k, v in g.super_set {
			for vk in v {
				delete(vk)
			}
			delete(v)
		}
		delete(g.super_set)
	}

	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "SATA Buddy")
	rl.SetTargetFPS(60)

	pix_font = rl.LoadFont("assets/compass-pro-v1.1/CompassPro.ttf")

	init_game(g, &d)

	defer destroy_game(g)
	defer doc_destroy(&d)

	for (!g.user_quit && !rl.WindowShouldClose()) { 	// Detect window close button or ESC key
		update_game(g)
		draw_game(g)

		// Frees short-lived objects that don't live beyond a single tick.
		free_all(context.temp_allocator)
	}
}

Question :: struct {
	question:     string,
	proposed:     [dynamic]string,
	real_answers: [4]bool,
	user_answers: [4]bool,
}

destroy_question :: proc(q: ^Question) {
	delete(q.question)
	delete(q.proposed)
	free(q)
}

destroy_questions :: proc(g: ^Game) {
	for q in g.question_bank {
		destroy_question(q)
	}
	// Clear that shit.
	clear(&g.question_bank)
	//delete(g.question_bank) // segfault, I'll just clear at program quit.
}

reset_questions :: proc(g: ^Game) {
	for q in g.question_bank {
		//mem.zero_slice(q.real_answers[:]) // This isn't supposed to be cleared!
		mem.zero_slice(q.user_answers[:])
	}
}

create_questions :: proc(g: ^Game) {
	for i := 0; i < TOTAL_QUESTIONS; i += 1 {
		q := create_question(g.doc)
		append(&g.question_bank, q)
	}
}

create_question :: proc(d: ^Doc) -> ^Question {
	question_form :: struct {
		q:        string,
		category: string,
	}

	canonical_questions := []question_form {
		{q = "Select the microbe form of the disease: \"%s\"", category = "microbe_form"},
		 {
			q = "Select all possible modes of transmission for the disease: \"%s\"",
			category = "transmission",
		},
		 {
			q = "What are the possible signs and symptoms for the disease: \"%s\"",
			category = "signs_symptoms",
		},
		 {
			q = "Which possible complications may occur for the disease: \"%s\"",
			category = "complications",
		},
		 {
			q = "Which nursing interventions apply for the disease: \"%s\"",
			category = "nursing_interventions",
		},
		{q = "A vaccine exists for disease: \"%s\"", category = "vaccine_available"},
	}


	// Choose starting selection.
	selected_disease := rand.choice(d.decks[:])
	selected_question := rand.choice(canonical_questions)

	// Create our question.
	q := new(Question)
	q.question = fmt.aprintf(selected_question.q, selected_disease["subject"])

	correct_count := rand.int_max(3) + 1
	incorrect_count := 4 - correct_count
	selected_correct: [dynamic]string
	defer delete(selected_correct)

	all_possible_correct := make(map[string]bool)
	defer delete(all_possible_correct)
	res := strings.split(selected_disease[selected_question.category], "/")
	defer delete_slice(res)
	cleaned := make([dynamic]string)
	defer delete(cleaned)


	for s in res {
		trmd := strings.trim(s, " ")
		append(&cleaned, trmd)
		all_possible_correct[trmd] = true
	}

	// fmt.println(
	// 	"len(cleaned):",
	// 	len(cleaned),
	// 	"len(all_possible_correct):",
	// 	len(all_possible_correct),
	// )

	rand.shuffle(cleaned[:])
	correct_count = math.min(len(cleaned), correct_count)
	// fmt.println("CORRECT_COUNT:", correct_count)
	// fmt.println("INCORRECT_COUNT:", incorrect_count)
	// fmt.println("TOTAL:", correct_count + incorrect_count)

	// fmt.println("hi")

	dupes := make(map[string]bool)
	defer delete(dupes)

	got := 0
	for got != correct_count {
		rc := rand.choice(cleaned[:])
		if rc not_in dupes {
			append(&selected_correct, rc)
			dupes[rc] = true
			got += 1
		}
	}

	// fmt.println("len(SELECTED_CORRECT):", len(selected_correct))

	// fmt.println("a")

	// Now select "wrong" answers.
	master_list := make(map[string]bool)
	defer delete(master_list)
	for disease in d.decks {
		if disease["subject"] != selected_disease["subject"] {
			res := strings.split(disease[selected_question.category], "/")
			defer delete_slice(res)

			for s in res {
				master_list[strings.trim(s, " ")] = true
			}
		}
	}

	//fmt.println("b")

	// Filter out anything that is correct for the disease in question.
	filtered_map := make(map[string]bool)
	defer delete(filtered_map)
	for s in master_list {
		if s not_in all_possible_correct {
			filtered_map[s] = true
		}
	}

	//fmt.println("c")

	selected_incorrect := make([dynamic]string)
	defer delete(selected_incorrect)

	cnt := 0
	for k in filtered_map {
		if cnt >= incorrect_count {
			break
		}
		append(&selected_incorrect, k)
		cnt += 1
	}

	//fmt.println("d")

	rand.shuffle(selected_incorrect[:])
	incorrect_count = math.min(incorrect_count, len(selected_incorrect))
	final_incorrect_list := selected_incorrect[0:incorrect_count]

	// The final proposed list is selected_correct + final_incorrect_list
	final_proposed := make([dynamic]string)

	//fmt.println("len(SELECED_INCORRECT):", len(selected_incorrect))

	for s in selected_correct {
		append(&final_proposed, s)
	}
	for s in selected_incorrect {
		append(&final_proposed, s)
	}

	// fmt.println("FINAL_PROPOSED:", final_proposed)

	// fmt.println("e")
	// fmt.println("len(final_proposed):", len(final_proposed))

	// Shuffle the final_proposed
	rand.shuffle(final_proposed[:])

	// Iterate and assign out real answers.
	for s, idx in final_proposed {
		if s in all_possible_correct {
			q.real_answers[idx] = true
		}
	}

	//fmt.println("f")

	q.proposed = final_proposed

	//fmt.println("g")

	assert(len(q.proposed) <= 4, "More than 4 questions detected!!")

	return q
}

is_user_correct :: proc(g: ^Game) -> bool {
	result := true
	for i := 0; i < len(g.question_bank[g.question_number].user_answers); i += 1 {
		if g.question_bank[g.question_number].user_answers[i] !=
		   g.question_bank[g.question_number].real_answers[i] {
			result = false
			break
		}
	}
	return result
}

has_user_selected :: proc(g: ^Game) -> bool {
	at_least_one_selected := false
	for i := 0; i < len(g.question_bank[g.question_number].user_answers); i += 1 {
		if g.question_bank[g.question_number].user_answers[i] {
			at_least_one_selected = true

		}
	}
	return at_least_one_selected
}

handle_quit_clicked :: proc(g: ^Game) {
	os.exit(0)
}

handle_cont_clicked :: proc(g: ^Game) {
	switch g.state {
	case .Answering:
		// For now, just move to grading mode if the user selected at least one choice.
		if !has_user_selected(g) {
			// Nothing selected, then just do nothing.
			return
		}

		g.state = .Grading
	case .Grading:
		// Score the user.
		if is_user_correct(g) {
			g.correct += 1
		}
		if !is_user_correct(g) {
			g.incorrect += 1
		}

		// Check when we're at the end.
		if (g.correct + g.incorrect) == TOTAL_QUESTIONS {
			g.state = .End
			return
		}

		g.state = .Intermission
	case .Intermission:
		g.question_number += 1

		// Get the next question!
		g.state = .Answering
	case .End:
		// Nothing for now.
		g.question_number = -1
		g.correct = 0
		g.incorrect = 0
		rebuild_question_bank(g)
		g.state = .Intermission
	}
}

rebuild_question_bank :: proc(g: ^Game) {
	switch g.user_mode {
	case .Fresh:
		// CRASHING: This path crashes bruh!
		destroy_questions(g)
		create_questions(g)
	case .Review:
		// This one isn't crashing dufus
		reset_questions(g)
	}
}

init_game :: proc(g: ^Game, d: ^Doc) {
	// Load data
	if result_bytes, ok := os.read_entire_file_from_filename(
		"contagious_diseases.json",
		context.temp_allocator,
	); ok {
		// temp_allocator doesn't work here, because now the fields of the struct will be empty.
		if err := json.unmarshal(result_bytes, d); err != nil {
			panic("Error unmarshaling struct!")
		}
	}

	// Set Raylib styles
	f := rl.LoadFont("Bookerly.ttf")
	rl.GuiSetFont(f)

	rl.GuiSetStyle(i32(rl.GuiControl.DEFAULT), i32(rl.GuiDefaultProperty.TEXT_SIZE), 30)
	rl.GuiSetStyle(i32(rl.GuiControl.TEXTBOX), i32(rl.GuiDefaultProperty.TEXT_SIZE), 25)
	rl.GuiSetStyle(i32(rl.GuiControl.TEXTBOX), i32(rl.GuiControlProperty.TEXT_PADDING), 2)
	//rl.GuiSetStyle(i32(rl.GuiControl.DEFAULT), i32(GuiTextWrapMode.TEXT_WRAP_WORD))
	rl.GuiSetStyle(i32(rl.GuiControl.DEFAULT), i32(rl.GuiDefaultProperty.TEXT_LINE_SPACING), 30)
	rl.GuiSetStyle(i32(rl.GuiControl.CHECKBOX), i32(rl.GuiControlProperty.TEXT_PADDING), 10)

	// rl.GuiSetStyle(
	// 	rl.GuiControl.BUTTON,
	// 	rl.GuiControlProperty.TEXT_ALIGNMENT,
	// 	GuiTextAlignment.TEXT_ALIGN_LEFT,
	// )
	// rl.GuiSetStyle(rl.GuiControl.BUTTON, rl.GuiControlProperty.TEXT_PADDING, 2)

	// Build simulation
	g.paused = false
	create_questions(g)
}

update_game :: proc(g: ^Game) {
	if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
		g.paused = !g.paused
	}

	if g.paused {
		return
	}
}

draw_game :: proc(g: ^Game) {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.ClearBackground(rl.WHITE)
	rl.DrawFPS(10, SCREEN_HEIGHT - 10 - 8)

	switch g.state {
	case .Answering:
		draw_card(g)
	case .Grading:
		draw_card(g)
		draw_grading(g)
	case .Intermission:
		// For now draw nothing and automatically move to next state.
		// Kind of a hack.
		handle_cont_clicked(g)
	case .End:
		draw_end(g)
	}

	//rl.DrawText(tcstring(fmt.tprintf("%s", g.state)), 30, 60, 30, rl.RED)

	if g.paused {
		text :: "GAME PAUSED"
		rl.DrawText(
			text,
			SCREEN_WIDTH / 2 - rl.MeasureText(text, 40) / 2,
			SCREEN_WIDTH / 2 - 40,
			40,
			rl.GRAY,
		)
	}
}

draw_card :: proc(g: ^Game) {
	c := g.card
	rl.GuiLabel(
		rl.Rectangle{SCREEN_MARGIN, 20, 300, 40},
		tcstring(fmt.tprintf("Question %d of %d:", g.question_number + 1, TOTAL_QUESTIONS)),
	)
	rl.GuiLabel(
		rl.Rectangle{SCREEN_WIDTH - (SCREEN_MARGIN * 10), 20, 300, 40},
		tcstring(fmt.tprintf(" Correct: %d, Incorrect: %d", g.correct, g.incorrect)),
	)

	rl.GuiTextBox(
		rl.Rectangle{SCREEN_MARGIN, 30 * 2, SCREEN_WIDTH - (SCREEN_MARGIN * 2), 200},
		tcstring(g.question_bank[g.question_number].question),
		16,
		false,
	)

	for i := 0; i < len(g.question_bank[g.question_number].proposed); i += 1 {
		evtHandled := false
		current_prop := g.question_bank[g.question_number].proposed[i]
		is_real_answer := g.question_bank[g.question_number].real_answers[i]
		if rl.GuiButton(
			rl.Rectangle{142, 300 + ((80 * f32(i))), SCREEN_WIDTH - 140 - (SCREEN_MARGIN * 3), 40},
			"",
		) {
			g.question_bank[g.question_number].user_answers[i] =
			!g.question_bank[g.question_number].user_answers[i]
			evtHandled = true
		}

		stubBool := false
		whichPtr :=
			&stubBool if evtHandled else &g.question_bank[g.question_number].user_answers[i]

		ans := tcstring(
			fmt.tprintf(
				"%c.) %s %s",
				65 + i,
				current_prop,
				"+" if rl.IsKeyDown(rl.KeyboardKey.LEFT_SHIFT) && is_real_answer else "",
			),
		)

		if rl.GuiCheckBox(rl.Rectangle{100, 300 + ((80 * f32(i))), 40, 40}, ans, whichPtr) {
			fmt.printf(
				"checkbox[%d] was toggled to the %s state...\n",
				i,
				"ON" if g.question_bank[g.question_number].user_answers[i] else "OFF",
			)
		}
	}

	// Don't render the grade button yet.
	if !has_user_selected(g) {
		return
	}

	if rl.GuiButton(
		rl.Rectangle {
			SCREEN_MARGIN,
			SCREEN_HEIGHT - (SCREEN_MARGIN * 4),
			SCREEN_WIDTH - (SCREEN_MARGIN * 2),
			60,
		},
		"Check" if g.state == .Answering else "Next Question",
	) {
		handle_cont_clicked(g)
	}
}

draw_grading :: proc(g: ^Game) {
	ALPHA :: 0.20

	for i := 0; i < len(g.question_bank[g.question_number].proposed); i += 1 {
		is_correct := g.question_bank[g.question_number].real_answers[i]
		if !is_correct {
			continue
		}

		rl.DrawRectangle(
			142,
			300 + (80 * i32(i)),
			SCREEN_WIDTH - 140 - (SCREEN_MARGIN * 3),
			40,
			rl.Fade(rl.GREEN, ALPHA),
		)
	}

	if is_user_correct(g) {
		draw_grading_banner(g, "CORRECT")
	} else {
		draw_grading_banner(g, "WRONG")
	}
}

draw_grading_banner :: proc(g: ^Game, msg: string) {
	offset :: 5
	padding :: 20

	c_msg := tcstring(msg)
	meas_res := rl.MeasureTextEx(pix_font, c_msg, fs, 2)

	meas_x := int(meas_res[0])
	meas_y := int(meas_res[1])

	w := meas_x + padding
	h := meas_y + padding

	colr := rl.GREEN if msg == "CORRECT" else rl.PINK

	middle_h := (SCREEN_WIDTH / 2) - (w / 2)
	middle_v := (SCREEN_HEIGHT / 2) - (h / 2)
	rl.DrawRectangle(
		i32(middle_h) + i32(offset),
		i32(middle_v) + i32(offset),
		i32(w),
		i32(h),
		colr,
	)
	rl.DrawRectangle(i32(middle_h), i32(middle_v), i32(w), i32(h), rl.WHITE)
	rl.DrawRectangleLinesEx(rl.Rectangle{f32(middle_h), f32(middle_v), f32(w), f32(h)}, 3, colr)

	fs :: 60

	rl.DrawTextEx(
		pix_font,
		c_msg,
		rl.Vector2 {
			f32((SCREEN_WIDTH / 2) - (meas_x / 2)),
			f32((SCREEN_HEIGHT / 2) - (meas_y / 2)),
		},
		fs,
		2,
		colr,
	)
}

draw_end :: proc(g: ^Game) {
	final_score := fmt.tprintf(
		"You're final score is: \n%.2f%%",
		(f32(g.correct) / f32(TOTAL_QUESTIONS)) * 100.0,
	)

	rl.GuiTextBox(
		rl.Rectangle{SCREEN_MARGIN, 30 * 2, SCREEN_WIDTH - (SCREEN_MARGIN * 2), 200},
		tcstring(final_score),
		16,
		false,
	)

	BTN_WIDTH :: 300

	if rl.GuiButton(
		rl.Rectangle{SCREEN_MARGIN, SCREEN_HEIGHT - (SCREEN_MARGIN * 4), BTN_WIDTH, 60},
		"Same Questions",
	) {
		g.user_mode = .Review
		handle_cont_clicked(g)
	}

	if rl.GuiButton(
		rl.Rectangle {
			(SCREEN_MARGIN * 2) + BTN_WIDTH,
			SCREEN_HEIGHT - (SCREEN_MARGIN * 4),
			BTN_WIDTH,
			60,
		},
		"New Questions",
	) {
		g.user_mode = .Fresh
		handle_cont_clicked(g)
	}

	if rl.GuiButton(
		rl.Rectangle {
			(SCREEN_MARGIN * 3) + (BTN_WIDTH * 2),
			SCREEN_HEIGHT - (SCREEN_MARGIN * 4),
			BTN_WIDTH,
			60,
		},
		"Quit",
	) {
		g.user_quit = true
	}
}
