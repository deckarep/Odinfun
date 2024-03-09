package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

// Run with: odin run test.odin -file -debug


Doc :: struct {
	super_set: map[string]map[string]u8,
}

boom :: proc(txt: string) {
	fmt.printf("ERROR: %s\n", txt)
	// No idea why panic text doesn't show up, but at least it stops the program.
	panic(txt)
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
	// TODO: Read this: https://gingerbill.gitbooks.io/odin-by-example/content/
	// TODO: Read this: https://www.gingerbill.org/series/memory-allocation-strategies/
	when ODIN_DEBUG {
		fmt.println("Odin in debug mode!")

		// Since context is scope bound, it must be set in main.
		context.allocator = start_tracking_allocator()
		defer finish_tracking_allocator()

		_real_main()
	} else {
		_real_main()
	}
}

do_slice :: proc() {
	foo :: struct {
		elements: [dynamic]int,
	}
	f := foo{}
	fmt.println("start is nil: ", f.elements == nil)
	fmt.println("start:", f.elements)

	for i := 0; i < 500; i += 1 {
		append(&f.elements, i)
	}
	fmt.println(f.elements[1])
	fmt.println("next:", f.elements)
	fmt.println("nil check 2:", f.elements == nil)
	delete(f.elements)


	fmt.println("post delete:", f.elements)
	for i := 0; i < 10_000; i += 1 {
		append(&f.elements, i)
	}
	fmt.println("end", f.elements)
}

_real_main :: proc() {
	do_slice()

	// Example stack alloc buffer
	buf: [256]u8
	str := fmt.bprintf(buf[:], "%s = %d", "hello world how are you doing?", 69)
	fmt.println(str)


	m := make(map[string]map[string]u8)

	doc := Doc {
		super_set = m,
	}

	s := "foo/ bar/ baz"

	defer {
		for _, v in m {
			for s in v {
				delete(s)
			}
			delete(v)
		}
		delete(m)
	}

	res := strings.split(s, "/")
	defer delete(res)
	for r in res {
		b := strings.trim(r, " ")
		s := strings.clone(b)

		category := "contagious"
		set := m[category]
		if _, ok := m[category]; !ok {
			set = make(map[string]u8)
			m[category] = set
		}

		set[s] = 1
	}


	fmt.println("hello!")
	fmt.println(m)

	doStack()

	// for i := 0; i < 100; i += 1 {
	// 	_ = new([1_000]int)
	// }

	// when ODIN_DEBUG {
	// 	finish_tracking_allocator(track)
	// }
}

doStack :: proc() {
	arena: virtual.Arena
	buf: [150]byte
	fmt.println("start buf")
	fmt.println(buf)
	if arena_init_error := virtual.arena_init_buffer(&arena, buf[:]); arena_init_error != nil {
		boom("Oh no!")
	}

	fmt.println("after arena_init_buffer")
	fmt.println(buf)

	aAlloc := virtual.arena_allocator(&arena)

	res, err := strings.split("You/ Ain't/ Seen/ Nothing/ Yet!", "/", allocator = aAlloc)
	if err != nil {
		boom("1st split failed!")
	}
	fmt.println(res)

	fmt.println("after 1st split")
	fmt.println(buf)
	free_all(aAlloc)

	fmt.println("after free_all")
	fmt.println(buf)

	res, err = strings.split("Boom/ Bam/ Zham/ Zol/ Zoo/ Zun!", "/", allocator = aAlloc)
	if err != nil {
		boom("2nd split failed!")
	}
	fmt.println(res)

	fmt.println("after 2nd split")
	fmt.println(buf)
}
