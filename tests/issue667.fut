type point = (f32, f32)

let f (p1: point) (p2: point) =
  let points = [p1,p2]
  let isingrid = [(f32.abs(p1.2) <= 1),
                  (f32.abs(p2.2) <= 2)]
  let (truepoints, _) = unzip( filter (\(_, x) -> x) (zip points isingrid))
  in truepoints[0]

entry main (p1s: []point) (p2s: []point) =
  map2 (\p1 p2 -> f p1 p2) p1s p2s
