// The oracle programs the differential suite compares against. One module for
// all of them, with no dependencies, so that `go run -C tools/differ/go ./x`
// works from a checkout with nothing fetched.
module differ

// 1.25 rather than the 1.24 pixi asks for, because `unicode.CategoryAliases`
// arrived in 1.25 and dumping it is the point of one of these programs.
go 1.25
