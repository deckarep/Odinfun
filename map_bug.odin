package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

Game :: struct {
	super_set: map[string]map[string]byte,
}

Deck :: struct {
	complications: string,
}

main :: proc() {
	fmt.println("Starting...")

	g := Game {
		super_set = make(map[string]map[string]byte),
	}

	decks := [7]Deck {
		{complications = "foo/ bar/ baz"},
		{complications = "bam/ pow/ boom"},
		{complications = "what/ the/ hell"},
		{complications = "everybody/ wang/ chung/ tonight"},
		{complications = "its/ time/ to/ dance"},
		{complications = "hold/ on/ to/ your/ butts"},
		{complications = "i/ cant/ think/ of/ anything/ else"},
	}

	// Loop over all decks, split the strings on forward slash and build up a map of categories of individual words.
	// TODO: proper mem cleanup. 

	for d in decks {
		res := strings.split(d.complications, "/")
		defer delete_slice(res)
		for s in res {
			new_s := strings.trim(s, " ")
			if "complications" not_in g.super_set {
				g.super_set["complications"] = make(map[string]byte)
			}
			comp_map := &g.super_set["complications"]
			item := strings.clone(new_s)

			// This line causes the program to be in a busy spin loop.
			comp_map[item] = 1
		}
	}

	fmt.println("Never reach this line!")
}
