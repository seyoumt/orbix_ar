package com.difrancescogianmarco.arcore_flutter_plugin.flutter_models

import com.difrancescogianmarco.arcore_flutter_plugin.utils.DecodableUtils
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.rendering.Material
import com.google.ar.sceneform.rendering.ModelRenderable
import com.google.ar.sceneform.rendering.ShapeFactory

class FlutterArCoreShape(map: HashMap<String, *>) {

    val dartType: String = map["dartType"] as String
    val materials: ArrayList<FlutterArCoreMaterial> = getMaterials(map["materials"] as ArrayList<HashMap<String, *>>)
    val radius: Float? = (map["radius"] as? Double)?.toFloat()
    val size = DecodableUtils.parseVector3(map["size"] as? HashMap<String, Any>) ?: Vector3()
    val height: Float? = (map["height"] as? Double)?.toFloat()

    fun buildShape(material: Material): ModelRenderable? {
        // Center at node origin (0,0,0). Upstream used (0, 0.15, 0) which floated
        // markers 15 cm above hit points — wrong for measurement.
        val center = Vector3.zero()
        return when (dartType) {
            "ArCoreSphere" -> ShapeFactory.makeSphere(radius!!, center, material)
            "ArCoreCube" -> ShapeFactory.makeCube(size, center, material)
            "ArCoreCylinder" -> ShapeFactory.makeCylinder(radius!!, height!!, center, material)
            else -> //TODO return exception
                null
        }
    }

    private fun getMaterials(list: ArrayList<HashMap<String, *>>): ArrayList<FlutterArCoreMaterial> {
        return ArrayList(list.map { map -> FlutterArCoreMaterial(map) })
    }

    override fun toString(): String {
        return "dartType: $dartType\nradius: $radius\nsize: $size\nheight: $height\nmaterial: ${materials[0].toString()}"
    }
}