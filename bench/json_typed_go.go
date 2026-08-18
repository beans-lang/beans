package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type Row struct {
	ID     uint64  `json:"id"`
	UserID uint64  `json:"userId"`
	Active bool    `json:"active"`
	Score  float64 `json:"score"`
	Name   string  `json:"name"`
	Note   *string `json:"note"`
}

func main() {
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		os.Exit(2)
	}
	started := time.Now()
	var rows []Row
	if err := json.Unmarshal(data, &rows); err != nil {
		os.Exit(3)
	}
	elapsed := time.Since(started)
	var checksum uint64
	for i := range rows {
		row := &rows[i]
		checksum += row.ID + row.UserID + uint64(len(row.Name))
		if row.Active {
			checksum++
		}
		if row.Note != nil {
			checksum += uint64(len(*row.Note))
		}
	}
	nanos := uint64(elapsed.Nanoseconds())
	if nanos == 0 {
		nanos = 1
	}
	fmt.Printf("go_encoding_json size=%d records=%d nanos=%d mib_s=%d records_s=%d checksum=%d\n",
		len(data), len(rows), nanos,
		uint64(len(data))*1_000_000_000/nanos/1_048_576,
		uint64(len(rows))*1_000_000_000/nanos, checksum)
}
