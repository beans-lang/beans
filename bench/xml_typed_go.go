package main

import (
	"encoding/xml"
	"fmt"
	"os"
	"time"
)

type Row struct {
	ID     uint64  `xml:"id,attr"`
	UserID uint64  `xml:"userId,attr"`
	Active bool    `xml:"active"`
	Score  float64 `xml:"score"`
	Name   string  `xml:"name"`
	Note   *string `xml:"note"`
}

type Rows struct {
	Rows []Row `xml:"row"`
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
	var document Rows
	if err := xml.Unmarshal(data, &document); err != nil {
		os.Exit(3)
	}
	elapsed := time.Since(started)
	var checksum uint64
	for i := range document.Rows {
		row := &document.Rows[i]
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
	fmt.Printf("go_encoding_xml size=%d records=%d nanos=%d mib_s=%d records_s=%d checksum=%d\n",
		len(data), len(document.Rows), nanos,
		uint64(len(data))*1_000_000_000/nanos/1_048_576,
		uint64(len(document.Rows))*1_000_000_000/nanos, checksum)
}
