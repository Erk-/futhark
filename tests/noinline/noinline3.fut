-- ==
-- tags { no_opencl }
-- input { [1,2,3] [0,0,1] } output { [1,1,2] }
-- structure distributed { SegMap/Apply 1 }

let f (xs: []i32) i = xs[i]

let main xs is = map (\i -> #[noinline] f xs i) is
