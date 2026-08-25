package pal

pub struct Back {
    pub solid: Hsla = Hsla {}
    pub partial: Hsla = Hsla { s: 9.0 }
    pub deep: Wrap = Wrap {}
}

pub struct Wrap {
    pub inner: Hsla = Hsla { h: 7.0 }
}
