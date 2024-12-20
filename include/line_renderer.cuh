#pragma once

#include "tgaimage.cuh"
#include "model.cuh"

namespace line_renderer
{
    void draw(Vec2i p0, Vec2i p1, TGAImage &output, TGAColor color);
    void wireframe(Model *model, TGAImage *output, TGAColor color);
}