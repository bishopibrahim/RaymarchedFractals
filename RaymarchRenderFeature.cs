using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class RaymarchDepthRendererFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Tooltip("Material that contains a pass named RAYMARCH_DEPTH (ZWrite On, ZTest LEqual, writes SV_Depth).")]
        public Material raymarchMaterial = null;

        [Tooltip("Shader pass name to execute.")]
        public string raymarchPassName = "RAYMARCH_DEPTH";

        [Tooltip("Run after opaques so scene depth is available for testing.")]
        public RenderPassEvent passEvent = RenderPassEvent.AfterRenderingOpaques;

        [Tooltip("Only run on Game cameras.")]
        public bool gameCamerasOnly = true;
    }

    public Settings settings = new Settings();

    class RaymarchDepthPass : ScriptableRenderPass
    {
        private readonly Material _material;
        private readonly string _profilerTag = "Raymarch Depth Pass";
        private readonly string _shaderPassName;
        private readonly bool _gameCamerasOnly;

        // Shader property IDs (must match your shader)
        private static readonly int ID_InvProj = Shader.PropertyToID("_InvProjMat");
        private static readonly int ID_InvView = Shader.PropertyToID("_InvViewMat");
        private static readonly int ID_VP      = Shader.PropertyToID("_CameraVP");
        private static readonly int ID_CamPos  = Shader.PropertyToID("_CameraPos");

        private int _shaderPassIndex = -1;

#if UNITY_2022_1_OR_NEWER
        RTHandle _cameraColor;
        RTHandle _cameraDepth;
#else
        RenderTargetIdentifier _cameraColor;
        RenderTargetIdentifier _cameraDepth;
#endif

        public RaymarchDepthPass(Material mat, string shaderPassName, RenderPassEvent evt, bool gameCamerasOnly)
        {
            _material        = mat;
            _shaderPassName  = shaderPassName;
            _gameCamerasOnly = gameCamerasOnly;
            renderPassEvent  = evt;

            // Ensure the camera depth texture exists for sampling, if your shader reads it.
            ConfigureInput(ScriptableRenderPassInput.Depth);

            if (_material != null)
            {
                _shaderPassIndex = _material.FindPass(_shaderPassName);
                if (_shaderPassIndex < 0)
                    Debug.LogError($"[{nameof(RaymarchDepthRendererFeature)}] Pass '{_shaderPassName}' not found on material '{_material.shader.name}'.");
            }
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            // Bind the camera’s color + depth as the targets for this pass (do not clear).
            #if UNITY_2022_1_OR_NEWER
                        _cameraColor = renderingData.cameraData.renderer.cameraColorTargetHandle;
                        _cameraDepth = renderingData.cameraData.renderer.cameraDepthTargetHandle;
                        ConfigureTarget(_cameraColor, _cameraDepth);
            #else
                        _cameraColor = renderingData.cameraData.renderer.cameraColorTarget;
                        _cameraDepth = renderingData.cameraData.renderer.cameraDepthTarget;
                        ConfigureTarget(_cameraColor, _cameraDepth);
            #endif
            // No ConfigureClear(...) call – we preserve existing depth from opaques.
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_material == null || _shaderPassIndex < 0)
                return;

            var camData = renderingData.cameraData;
            if (_gameCamerasOnly && camData.cameraType != CameraType.Game)
                return;

            var cam = camData.camera;

            // Per-camera uniforms
            var invProj = cam.projectionMatrix.inverse;
            var invView = cam.cameraToWorldMatrix;                  // inverse of worldToCamera
            var vp      = cam.projectionMatrix * cam.worldToCameraMatrix;
            var camPos  = cam.transform.position;

            var cmd = CommandBufferPool.Get(_profilerTag);
            cmd.SetGlobalMatrix(ID_InvProj, invProj);
            cmd.SetGlobalMatrix(ID_InvView, invView);
            cmd.SetGlobalMatrix(ID_VP,      vp);
            cmd.SetGlobalVector(ID_CamPos,  camPos);

            // ConfigureTarget(...) in OnCameraSetup already bound color+depth for this pass.
            // Issue a full-screen procedural triangle draw; vertex must support SV_VertexID.
            cmd.DrawProcedural(Matrix4x4.identity, _material, _shaderPassIndex, MeshTopology.Triangles, 3, 1);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            // No temporary allocations to release.
        }
    }

    RaymarchDepthPass _pass;

    public override void Create()
    {
        _pass = new RaymarchDepthPass(
            settings.raymarchMaterial,
            settings.raymarchPassName,
            settings.passEvent,
            settings.gameCamerasOnly
        );
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (settings.raymarchMaterial == null)
            return;

        renderer.EnqueuePass(_pass);
    }
}
