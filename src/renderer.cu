
#include <limits>

#include "../include/renderer.cuh"

#define BLOCK_SIZE 256

namespace renderer
{

	namespace
	{ // private functions

		/**
		 * Given three vertices of a triangle and a point P, returns the barycentric coordinates of P in relation to the triangle.
		 * If triangle is degenerate, returns a negative coordinate in X.
		 */
		__device__ Vec3f barycentric(Vec3f triangle[3], Vec2i p)
		{
			Vec3f vAB = triangle[1] - triangle[0];
			Vec3f vAC = triangle[2] - triangle[0];
			Vec3f vPA = triangle[0] - Vec3f(p.x, p.y, 0);

			Vec3f cross /* (u*w, v*w, w) */ = Vec3f(vAB.x, vAC.x, vPA.x).cross(Vec3f(vAB.y, vAC.y, vPA.y));

			float w = cross.z;
			if (abs(w) < 1e-6)
			{
				// w is actually the triangle's area, such that w == 0 indicates a degenerate triangle
				// in which case return a negative coordinate so that it is discarded
				return Vec3f(-1, 1, 0);
			}

			float u = cross.x / w;
			float v = cross.y / w;

			// even though its mathematically equivalent and more readable, 1.0f - u - v gives rounding
			// errors that lead to missing pixels on triangle edges. 1.0f - (cross.x+cross.y) / w somehow
			// avoids this.
			return Vec3f(1.0f - (cross.x + cross.y) / w, u, v);
		}

		__global__ void render_face(
			int face_index,
			int width,
			float *z_buffer,
			IShader *shader,
			TGAImage *output)
		{
			// vertex shader
			Vec3f vertices[3];
			for (int i = 0; i < 3; i++)
			{
				vertices[i] = shader->vertex(face_index, i).dehomogenize();
			}

			// backface culling
			Vec3f normal = ((vertices[1] - vertices[0]).cross(vertices[2] - vertices[0]));
			Vec3f model_to_camera_dir = Vec3f(0, 0, 1);
			if (normal.dot(model_to_camera_dir) < 0)
			{
				return;
			}

			// triangle's bounding box (bb)
			Vec2i bounds[2] = {
				Vec2i(
					min(vertices[0].x, min(vertices[1].x, vertices[2].x)),
					min(vertices[0].y, min(vertices[1].y, vertices[2].y))),
				Vec2i(
					max(vertices[0].x, max(vertices[1].x, vertices[2].x)),
					max(vertices[0].y, max(vertices[1].y, vertices[2].y)))};

			// iterate over pixels contained in bb
			for (int x = bounds[0].x; x <= bounds[1].x; x++)
			{
				for (int y = bounds[0].y; y <= bounds[1].y; y++)
				{

					Vec3f barycentric_coords = barycentric(vertices, Vec2i(x, y));

					if (barycentric_coords.x < 0 || barycentric_coords.y < 0 || barycentric_coords.z < 0)
					{
						// pixel is not inside triangle, also ignores degenerate triangles
						continue;
					}

					// find pixel's z by interpolating barycentrinc coords
					float pixel_z =
						vertices[0].z * barycentric_coords.x +
						vertices[1].z * barycentric_coords.y +
						vertices[2].z * barycentric_coords.z;

					if (z_buffer[(x * width) + y] > pixel_z)
					{
						// there is already something drawn in front of this pixel
						continue;
					}
					z_buffer[(x * width) + y] = pixel_z;

					// fragment shader
					TGAColor color = TGAColor(0, 0, 0, 0);
					if (!shader->fragment(barycentric_coords, color))
					{
						continue;
					}

					output->set(x, y, color);
				}
			}
		}

		__global__ void initialize_z_buffer(float *z_buffer, size_t size, float initial_value)
		{
			int idx = blockIdx.x * blockDim.x + threadIdx.x;
			if (idx >= size) return;
			z_buffer[idx] = initial_value;
		}

	}

	Matrix4 viewport(int w, int h)
	{
		Matrix4 m;
		constexpr int Z_DEPTH = 255;
		// scaling part
		m.m[0][0] = (w / 2.0f);
		m.m[1][1] = (h / 2.0f);
		m.m[2][2] = (Z_DEPTH / 2.0f);
		// translating part
		for (int i = 0; i < 3; i++)
		{
			m.m[i][3] = m.m[i][i];
		}

		return m;
	}

	Matrix4 projection(float c)
	{
		Matrix4 m;
		m.m[3][2] = -(1 / c);
		return m;
	}

	Matrix4 loot_at(Vec3f eye, Vec3f target, Vec3f up)
	{
		Vec3f z = (eye - target).normalize();
		Vec3f x = up.cross(z).normalize();
		Vec3f y = z.cross(x).normalize();

		Matrix4 translation = Matrix4::identity();
		Matrix4 inv_basis = Matrix4::identity();

		for (int i = 0; i < 3; i++)
		{
			translation.m[i][3] = -eye.raw[i];

			inv_basis.m[0][i] = x.raw[i];
			inv_basis.m[1][i] = y.raw[i];
			inv_basis.m[2][i] = z.raw[i];
		}

		return inv_basis * translation;
	}

	void render(TGAImage &output, Model &model, IShader &shader, size_t sizeof_shader)
	{
		// TODO fix!

		// initialize z-buffer
		size_t z_buffer_size = output.get_width() * output.get_height();
		float *d_z_buffer;
		cudaMalloc(&d_z_buffer, z_buffer_size * sizeof(float));

		size_t num_blocks = std::ceil(z_buffer_size / (float)BLOCK_SIZE);
		initialize_z_buffer<<<num_blocks, BLOCK_SIZE>>>(d_z_buffer, z_buffer_size, -std::numeric_limits<float>::max());

		// create device pointers for parameters
		TGAImage *d_output_image;
		Model *d_model;
		IShader *d_shader;
		cudaMalloc(&d_output_image, sizeof(TGAImage));
		cudaMalloc(&d_model, sizeof(Model));
		cudaMalloc(&d_shader, sizeof_shader);

		// compute transformation matrices for the shader
		shader.m_viewport = viewport(output.get_width(), output.get_height());
		shader.transform = shader.m_viewport * shader.m_projection * shader.m_view;
		shader.model = d_model;

		// copy all parameters to device
		cudaMemcpy(d_output_image, &output, sizeof(TGAImage), cudaMemcpyHostToDevice);
		cudaMemcpy(d_model, &model, sizeof(Model), cudaMemcpyHostToDevice);
		cudaMemcpy(d_shader, &shader, sizeof_shader, cudaMemcpyHostToDevice);

		// make sure z_buffer is initialized
		cudaDeviceSynchronize(); 

		// render each face!
		for (int i = 0; i < model.nfaces(); i++)
		{
			// TODO actually parallelize this
			render_face<<<1, 1>>>(i, output.get_width(), d_z_buffer, d_shader, d_output_image);
		}

		// make sure faces are rendered
		cudaDeviceSynchronize(); 

		// copy result back to output image
		cudaMemcpy(&output, d_output_image, sizeof(TGAImage), cudaMemcpyDeviceToHost);

		// free all the mallocs
		cudaFree(d_z_buffer);
		cudaFree(d_output_image);
		cudaFree(d_model);
		cudaFree(d_shader);
	}

}