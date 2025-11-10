Shader "Unlit/FractalMarchShader"
{
    Properties
    {
        _MaxDist     ("Max Distance",  Float) = 100.0
        _MinDist     ("Min Distance",  Float) = 0.01
        _Brightness  ("Brightness",    Float) = 1.0
        _SphereRadius("Radius",        Float) = 1.0
        _Damping     ("Damping",       Float) = 1.0
        _Fade        ("Fade",          Float) = 1.0
        _DepthFalloff ("Depth Falloff", Float) = 1.0
        _Exponent ("Exponent", Float) = 1.0
        _Iterations ("Escape Time Iterations", Float) = 32
        _MaxRad ("Escape Radius", Float) = 4.0
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }

        Pass
        {
            Name "RAYMARCH_DEPTH"
            Cull Off
            ZWrite On
            ZTest LEqual

            CGPROGRAM
            #pragma target 4.5
            #pragma vertex VertFSQ // FullScreen Quad
            #pragma fragment Frag
            #include "UnityCG.cginc"

            // Fullscreen procedural triangle (no vertex buffer required)
            struct VSOut 
            {
                float4 pos : SV_POSITION;
                float2 uv  : TEXCOORD0;
            };

            struct FragOut 
            { 
                float4 col : SV_Target; 
                float depth : SV_Depth; 
            };

            VSOut VertFSQ(uint vid : SV_VertexID) // Draws screen-space quad - DO NOT TOUCH
            {
                float2 pos[3] = { float2(-1,-1), float2( 3,-1), float2(-1, 3) };
                float2 uv[3]  = { float2( 0, 0), float2( 2, 0), float2( 0, 2) };
                VSOut o;
                o.pos = float4(pos[vid], 0, 1);
                o.uv  = uv[vid];
                return o;
            }

            // Camera uniforms (names must match what the feature sets)
            float4x4 _InvProjMat;
            float4x4 _InvViewMat;
            float4x4 _CameraVP;
            float3   _CameraPos;     // <-- match feature

            // Controls
            float _MinDist;
            float _MaxDist;
            float _Brightness;
            float _SphereRadius;
            float _Damping;
            float _Fade;
            float _DepthFalloff;
            float _Exponent;
            float _Iterations; 
            float _MaxRad;

            // Robust ray dir from near/far reconstruction
            float3 ComputeRayDir(float2 uv)
            {
                float2 ndc = uv * 2.0 - 1.0; // normalized device coordinates
                ndc.y *= -1.0;

                float4 vN = mul(_InvProjMat, float4(ndc, 0.0, 1.0)); 
                vN /= vN.w;

                float3 wN = mul(_InvViewMat, float4(vN.xyz, 1.0)).xyz;

                return normalize(wN - _CameraPos);
            }

            float DE2(float3 p) // Sphere
            { 
                return length(p) - _SphereRadius; 
            }

            /*
            float RandomOffset(float2 uv) // returns a value between 0 and 1
            {
                float offset = cos(frac(sin(500*(uv.x * uv.y + uv.x + uv.y)) + 0.8763));
                offset = (offset*offset*offset*offset)*1287915;
                return frac(offset);
            }*/

            float DE(float3 z) // Sierpinski's Simplex
            {
                float3 a1 = normalize(float3(1,1,1));
                float3 a2 = normalize(float3(-1,-1,1));
                float3 a3 = normalize(float3(1,-1,-1));
                float3 a4 = normalize(float3(-1,1,-1));
                float3 c;
                int n = 0;
                float dist, d;
                while (n < 10) {
                    c = a1; dist = length(z-a1);
                        d = length(z-a2); if (d < dist) { c = a2; dist=d; }
                    d = length(z-a3); if (d < dist) { c = a3; dist=d; }
                    d = length(z-a4); if (d < dist) { c = a4; dist=d; }
                    z = 2.0*z-c*(2.0-1.0);
                    n++;
                }  

	            return length(z) * pow(2.0, float(-n));
            }

            float DE4(float3 z) // Sierpinski's Simplex Inverted + periodic length-dependent displacement
            {
                float3 center = normalize(float3(sin(_Time.y * _Exponent), cos(_Time.y * _Exponent), sin(_Time.y * 2 * _Exponent)));
                float3 zp = normalize(z) * pow(length(z-center), -1);
                return DE4(zp);
            }
/*
            float DE(float3 z) // Mandelbulb
            {
                int iter = (int)_Iterations;
                for (int i = 0; i < iter; i++)
                {

                }
            }*/
            
            float3 FiniteDifferenceNormal(float3 p, float eps)
            {
                const float3 X = float3(1,0,0);
                const float3 Y = float3(0,1,0);
                const float3 Z = float3(0,0,1);

                // Central differences along the axes
                float dx = DE(p + eps*X) - DE(p - eps*X);
                float dy = DE(p + eps*Y) - DE(p - eps*Y);
                float dz = DE(p + eps*Z) - DE(p - eps*Z);

                // Optional scaling to the true gradient: * (0.5/eps)
                // Direction is unchanged after normalize, so it’s not required.
                float3 g = float3(dx, dy, dz);

                // Guard to avoid NaNs if DE is flat/numeric noise
                float len2 = dot(g, g);
                if (len2 < 1e-20) return float3(0,0,1);

                return normalize(g);
            }

            float Lighting(float3 normal, float3 lightDir)
            {
                return dot(normal, lightDir) * 0.5 + 0.5;
            }

            FragOut Frag(VSOut i)
            {
                FragOut o;

                float3 rayOrigin = _CameraPos;
                float3 rayDir = ComputeRayDir(i.uv);
                float3 p = rayOrigin;
                int steps = 128;

                [loop]
                for (int j = 0; j < steps; j++)
                {
                    float d = DE(p);

                    if (d < _MinDist)
                    {
                        // Compute clip-space depth from world hit point
                        float4 clip = mul(_CameraVP, float4(p, 1.0));
                        o.depth = saturate(clip.z / clip.w);     

                        // Simple shading; replace as needed
                        float fade = (1.0 - (((float)j * _Fade) / steps));
                        float adjustedFade = fade * fade;
                        float3 normal = FiniteDifferenceNormal(p, 0.01);
                        o.col = float4(normal.xyz, 1.0)  * (1.0 / (1.0 + _DepthFalloff * length(_CameraPos - p))) * _Brightness * adjustedFade;
                        return o;
                    }

                    if (d > _MaxDist) break;

                    p += rayDir * d * _Damping;
                }

                // Miss: write far depth so this pass doesn’t occlude anything

                o.col   = float4(0, 0, 0, 1);
                o.depth = 1.0;
                return o;
            }
            ENDCG
        }
    }
}
